import Principal "mo:base/Principal";
import Debug "mo:base/Debug";
import Cycles "mo:base/ExperimentalCycles";
import Text "mo:base/Text";
import Buffer "mo:stable-buffer/StableBuffer";

import UserCanister "../user/User";

import CanisterMap "mo:candb/CanisterMap";
import CA "mo:candb/CanisterActions";
import Admin "mo:candb/CanDBAdmin";
import Utils "mo:candb/Utils";

shared ({caller = owner}) actor class IndexCanister() = this {
  stable var pkToCanisterMap = CanisterMap.init();

  /// @required API (Do not delete or change)
  ///
  /// Get all canisters for an specific PK
  ///
  /// This method is called often by the candb-client query & update methods. 
  public shared query({caller = caller}) func getCanistersByPK(pk: Text): async [Text] {
    getCanisterIdsIfExists(pk);
  };
  
  /// Helper function that creates a user canister for a given PK
  func createUserCanister(pk: Text, controllers: ?[Principal]): async Text {
    Debug.print("creating new user canister with pk=" # pk);
    Cycles.add(300_000_000_000);
    let newUserCanister = await UserCanister.UserCanister({
      partitionKey = pk;
      scalingOptions = {
        autoScalingCanisterId = Principal.toText(Principal.fromActor(this));
        sizeLimit = #count(3);
      };
      owners = ?[owner, Principal.fromActor(this)];
    });
    let newUserCanisterPrincipal = Principal.fromActor(newUserCanister);
    await CA.updateCanisterSettings({
      canisterId = newUserCanisterPrincipal;
      settings = {
        controllers = controllers;
        compute_allocation = ?0;
        memory_allocation = ?0;
        freezing_threshold = ?2592000;
      }
    });

    let newUserCanisterId = Principal.toText(newUserCanisterPrincipal);
    pkToCanisterMap := CanisterMap.add(pkToCanisterMap, pk, newUserCanisterId);

    newUserCanisterId;
  };

  /// @modify and @required (Do not delete or change the API, but must can modify the function logic for your given application actor and data model)
  ///
  /// This is method is called by CanDB for AutoScaling. It is up to the developer to specify which
  /// PK prefixes should spin up which canister actor.
  ///
  /// If the developer does not utilize this method, auto-scaling will NOT work
  public shared({caller = caller}) func createAdditionalCanisterForPK(pk: Text): async Text {
    Debug.print("creating additional canister for PK=" # pk);
    // If the call to auto-scale does not come from a canister from the same partition, disallow it
    if (Utils.callingCanisterOwnsPK(caller, pkToCanisterMap, pk)) {
      if (Text.startsWith(pk, #text("user#"))) {
        await createUserCanister(pk, ?[owner, Principal.fromActor(this)]);
      } else {
        Debug.trap("error: create case not covered");
      };
    } else {
      Debug.trap("error, called by non-controller=" # debug_show(caller));
    };
  };
  
  /// Public API endpoint for spinning up a canister from the User Actor
  public shared({caller = creator}) func createUser(): async ?Text {
    let callerPrincipalId = Principal.toText(creator);
    let userPk = "user#" # callerPrincipalId;
    let canisterIds = getCanisterIdsIfExists(userPk);
    // does not exist
    if (canisterIds == []) {
      ?(await createUserCanister(userPk, ?[owner, Principal.fromActor(this)]));
    // already exists
    } else {
      Debug.print("already exists, not creating and returning null");
      null 
    };
  };

  /// Spins down all canisters belonging to a specific user (transfers cycles back to the index canister, and stops/deletes all canisters)
  public shared({caller = caller}) func deleteLoggedInUser(): async () {
    let callerPrincipalId = Principal.toText(caller);
    let userPk = "user#" # callerPrincipalId;
    let canisterIds = getCanisterIdsIfExists(userPk);
    if (canisterIds == []) {
      Debug.print("canister for user with principal=" # callerPrincipalId # " pk=" # userPk # " does not exist");
    } else {
      // can choose to use this statusMap for to detect failures and prompt retries if desired 
      let statusMap = await Admin.transferCyclesStopAndDeleteCanisters(canisterIds);
      pkToCanisterMap := CanisterMap.delete(pkToCanisterMap, userPk);
    };
  };

  /// @required function (Do not delete or change)
  ///
  /// Helper method acting as an interface for returning an empty array if no canisters
  /// exist for the given PK
  func getCanisterIdsIfExists(pk: Text): [Text] {
    switch(CanisterMap.get(pkToCanisterMap, pk)) {
      case null { [] };
      case (?canisterIdsBuffer) { Buffer.toArray(canisterIdsBuffer) } 
    }
  };

  /// Upgrade user canisters in a PK range, i.e. rolling upgrades (limit is fixed at upgrading the canisters of 5 PKs per call)
  public shared({ caller = caller }) func upgradeUserCanistersInPKRange(wasmModule: Blob): async Admin.UpgradePKRangeResult {
    if (caller != owner) { // basic authorization
      return {
        upgradeCanisterResults = [];
        nextKey = null;
      }
    }; 

    await Admin.upgradeCanistersInPKRange({
      canisterMap = pkToCanisterMap;
      lowerPK = "user#";
      upperPK = "user#:";
      limit = 5;
      wasmModule = wasmModule;
      scalingOptions = {
        autoScalingCanisterId = Principal.toText(Principal.fromActor(this));
        sizeLimit = #count(20)
      };
      owners = ?[owner, Principal.fromActor(this)];
    });
  };
}