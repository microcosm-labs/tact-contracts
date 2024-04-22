// SPDX-License-Identifier: AGPL-3.0
// Copyright (C) Microcosm Labs 2023
// Authors: @0kenx
// GitHub: https://github.com/microcosm-labs

import "@stdlib/deploy";
import "@stdlib/ownable";
import "./utils/transfer_helpers";

// ======================== Messages ========================
message SetJettonWalletAddress {
    address: Address;
}

message RescueJetton {
    jetton_wallet_address: Address;
    amount: Int as coins;
}
// ======================== Events ========================

message JettonWalletAddressSetEvent {
    address: Address;
}

message WithdrawEvent {
    to: Address;
    amount: Int as coins;
}

message StageStatusSetEvent {
    stage_id: Int;
    status: Bool;
}

// ======================== Data Structures ========================

struct StageConfig {
    start_time: Int as uint32;
    unlock_amount: Int as coins;
}

struct UnlockConfig {
    total_stages: Int as uint32;
    stage_config: map<Int, StageConfig>;
}

/// Config can only be set at initialization.
struct TokenLockerConfig {
    total_jetton: Int as coins;
    recipient_address: Address;
    unlock_config: UnlockConfig;
}

/// Contract to lock up Jetton tokens in multiple stages and release them over time.
/// To use this contract, first initialize it with the TokenLockerConfig.
/// Then set the correct Jetton wallet address.
/// Lastly send the Jetton tokens to the contract. This completes the locking process. 
/// Nobody (including the owner) can withdraw the Jetton tokens until unlocked.
/// After each stage is unlocked, anyone can call the withdraw method to send the Jetton tokens to the recipient.
/// After all stages are unlocked and all Jetton tokens are withdrawn, 
/// the owner can call the withdraw dust method to withdraw any remaining dust,
/// and call the RescueJetton method to withdraw any Jetton tokens sent to the contract by mistake.
contract TonupTokenLocker with Deployable, OwnableTransferable {
    const STORAGE_GAS_RESERVE: Int = ton("0.2");
    const WITHDRAW_GAS: Int = ton("0.1");
    const TRANSFER_NOTIFICATION_GAS: Int = ton("0.12");

    owner: Address;
    config: TokenLockerConfig;
    jetton_wallet_address: Address?;
    amount_withdrawn: Int as coins = 0;

    init(owner: Address,
         config: TokenLockerConfig
    ) {
        self.owner = owner;
        self.config = config;

        let i: Int = 0;
        let total: Int = 0;
        repeat (config.unlock_config.total_stages) {
            require(config.unlock_config.stage_config.get(i) != null, "Invalid stage setting");
            let stage_config: StageConfig = config.unlock_config.stage_config.get(i)!!;
            total = total + stage_config.unlock_amount;
            i = i + 1;
        }
        require(total == config.total_jetton, "Total Jetton does not match");
    }

    // ======================== Admin Interface ========================
    // Fund the contract
    receive("fund gas") {}

    // Set up Jetton wallet address. This can only be set once.
    receive(msg: SetJettonWalletAddress) {
        self.requireOwner();
        require(self.jetton_wallet_address == null, "Jetton Wallet Address already set");
        self.jetton_wallet_address = msg.address;
        emit(JettonWalletAddressSetEvent{address: msg.address}.toCell());
        refund_gas();
    }

    /// Withdraw dust
    receive("withdraw dust") {
        self.requireOwner();
        let i: Int = 0;
        let total: Int = 0;
        repeat (self.config.unlock_config.total_stages) {
            let stage_config: StageConfig = self.config.unlock_config.stage_config.get(i)!!;
            total = total + stage_config.unlock_amount;
            i = i + 1;
        }
        require(total <= self.amount_withdrawn, "Not fully claimed yet");
        let dust_to_claim: Int = 0;
        dust_to_claim = myBalance() - context().value - self.STORAGE_GAS_RESERVE;
        send_ton(self.owner, dust_to_claim, false, "Withdraw dust".asComment());
    }

    /// Rescue tokens after locking period is over and all tokens are withdrawn (for example extra Jetton or the wrong Jetton is transferred to the contract)
    receive(msg: RescueJetton) {
        self.requireOwner();
        let i: Int = 0;
        let total: Int = 0;
        repeat (self.config.unlock_config.total_stages) {
            let stage_config: StageConfig = self.config.unlock_config.stage_config.get(i)!!;
            total = total + stage_config.unlock_amount;
            i = i + 1;
        }
        require(total <= self.amount_withdrawn, "Not fully claimed yet");
        send_jetton_text(msg.jetton_wallet_address, sender(), msg.amount, 0, false, "rescue");
    }

    // Receive Token Notification
    // If the token received is the same as the target token then accept, otherwise reject
    receive(msg: JettonTransferNotification) {
        require(context().value >= self.TRANSFER_NOTIFICATION_GAS, "Insufficient gas"); // avoid gas draining attacks
        if (context().sender != self.jetton_wallet_address!!) {
            send_jetton_text(context().sender, msg.sender, msg.amount, 0, false, "reject");
        }
        // otherwise do nothing to accept the transfer
    }

    // ======================== User Interface ========================

/// All Jetton tokens must be already sent to the contract before calling this method. 
/// Otherwise the withdrawal will fail and tokens will remain locked.
/// Anyone can call this method to initiate a withdraw to the recipient.
    receive("withdraw") {
        require(context().value >= self.WITHDRAW_GAS, "Insufficient gas");
        let i: Int = 0;
        let total: Int = 0;
        repeat (self.config.unlock_config.total_stages) {
            let stage_config: StageConfig = self.config.unlock_config.stage_config.get(i)!!;
            if (stage_config.start_time < now()) {
                total = total + stage_config.unlock_amount;
            }
            i = i + 1;
        }
        require(total > self.amount_withdrawn, "No more Jetton to withdraw");
        let amount_to_withdraw: Int = total - self.amount_withdrawn;
        self.amount_withdrawn = total;
        send_jetton_text(self.jetton_wallet_address!!, self.config.recipient_address, amount_to_withdraw, 0, true, "withdraw");
        emit(WithdrawEvent{to: self.config.recipient_address, amount: amount_to_withdraw}.toCell());
    }

    // ======================== View Interface ========================
    get fun config(): TokenLockerConfig {
        return self.config;
    }

    get fun balance(): Int {
        return myBalance();
    }


}
