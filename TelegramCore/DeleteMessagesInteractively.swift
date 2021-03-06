import Foundation
#if os(macOS)
    import PostboxMac
    import SwiftSignalKitMac
    import MtProtoKitMac
#else
    import Postbox
    import SwiftSignalKit
    import MtProtoKitDynamic
#endif

public enum InteractiveMessagesDeletionType {
    case forLocalPeer
    case forEveryone
}

public func deleteMessagesInteractively(postbox: Postbox, messageIds: [MessageId], type: InteractiveMessagesDeletionType) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Void in
        var messageIdsByPeerId: [PeerId: [MessageId]] = [:]
        for id in messageIds {
            if messageIdsByPeerId[id.peerId] == nil {
                messageIdsByPeerId[id.peerId] = [id]
            } else {
                messageIdsByPeerId[id.peerId]!.append(id)
            }
        }
        for (peerId, peerMessageIds) in messageIdsByPeerId {
            if peerId.namespace == Namespaces.Peer.CloudChannel || peerId.namespace == Namespaces.Peer.CloudGroup || peerId.namespace == Namespaces.Peer.CloudUser {
                cloudChatAddRemoveMessagesOperation(transaction: transaction, peerId: peerId, messageIds: peerMessageIds, type: CloudChatRemoveMessagesType(type))
            } else if peerId.namespace == Namespaces.Peer.SecretChat {
                if let state = transaction.getPeerChatState(peerId) as? SecretChatState {
                    var layer: SecretChatLayer?
                    switch state.embeddedState {
                        case .terminated, .handshake:
                            break
                        case .basicLayer:
                            layer = .layer8
                        case let .sequenceBasedLayer(sequenceState):
                            layer = sequenceState.layerNegotiationState.activeLayer.secretChatLayer
                    }
                    if let layer = layer {
                        var globallyUniqueIds: [Int64] = []
                        for messageId in peerMessageIds {
                            if let message = transaction.getMessage(messageId), let globallyUniqueId = message.globallyUniqueId {
                                globallyUniqueIds.append(globallyUniqueId)
                            }
                        }
                        let updatedState = addSecretChatOutgoingOperation(transaction: transaction, peerId: peerId, operation: SecretChatOutgoingOperationContents.deleteMessages(layer: layer, actionGloballyUniqueId: arc4random64(), globallyUniqueIds: globallyUniqueIds), state: state)
                        if updatedState != state {
                            transaction.setPeerChatState(peerId, state: updatedState)
                        }
                    }
                }
            }
        }
        transaction.deleteMessages(messageIds)
    }
}

public func clearHistoryInteractively(postbox: Postbox, peerId: PeerId) -> Signal<Void, NoError> {
    return postbox.transaction { transaction -> Void in
        if peerId.namespace == Namespaces.Peer.CloudUser || peerId.namespace == Namespaces.Peer.CloudGroup || peerId.namespace == Namespaces.Peer.CloudChannel {
            var topTimestamp: Int32?
            if let topIndex = transaction.getTopMesssageIndex(peerId: peerId, namespace: Namespaces.Message.Cloud) {
                topTimestamp = topIndex.timestamp
            }
            cloudChatAddClearHistoryOperation(transaction: transaction, peerId: peerId, explicitTopMessageId: nil)
            transaction.clearHistory(peerId)
            if let cachedData = transaction.getPeerCachedData(peerId: peerId) as? CachedChannelData, let migrationReference = cachedData.migrationReference {
                cloudChatAddClearHistoryOperation(transaction: transaction, peerId: migrationReference.maxMessageId.peerId, explicitTopMessageId: MessageId(peerId: migrationReference.maxMessageId.peerId, namespace: migrationReference.maxMessageId.namespace, id: migrationReference.maxMessageId.id + 1))
                transaction.clearHistory(migrationReference.maxMessageId.peerId)
            }
            if let topTimestamp = topTimestamp {
                updatePeerChatInclusionWithMinTimestamp(transaction: transaction, id: peerId, minTimestamp: topTimestamp)
            }
        } else if peerId.namespace == Namespaces.Peer.SecretChat {
            transaction.clearHistory(peerId)
            
            if let state = transaction.getPeerChatState(peerId) as? SecretChatState {
                var layer: SecretChatLayer?
                switch state.embeddedState {
                    case .terminated, .handshake:
                        break
                    case .basicLayer:
                        layer = .layer8
                    case let .sequenceBasedLayer(sequenceState):
                        layer = sequenceState.layerNegotiationState.activeLayer.secretChatLayer
                }
                
                if let layer = layer {
                    let updatedState = addSecretChatOutgoingOperation(transaction: transaction, peerId: peerId, operation: SecretChatOutgoingOperationContents.clearHistory(layer: layer, actionGloballyUniqueId: arc4random64()), state: state)
                    if updatedState != state {
                        transaction.setPeerChatState(peerId, state: updatedState)
                    }
                }
            }
        }
    }
}

public func clearAuthorHistory(account: Account, peerId: PeerId, memberId: PeerId) -> Signal<Void, NoError> {
    return account.postbox.transaction { transaction -> Signal<Void, Void> in
        if let peer = transaction.getPeer(peerId), let memberPeer = transaction.getPeer(memberId), let inputChannel = apiInputChannel(peer), let inputUser = apiInputUser(memberPeer) {
            
            let signal = account.network.request(Api.functions.channels.deleteUserHistory(channel: inputChannel, userId: inputUser))
                |> map { result -> Api.messages.AffectedHistory? in
                    return result
                }
                |> `catch` { _ -> Signal<Api.messages.AffectedHistory?, Bool> in
                    return .fail(false)
                }
                |> mapToSignal { result -> Signal<Void, Bool> in
                    if let result = result {
                        switch result {
                        case let .affectedHistory(pts, ptsCount, offset):
                            account.stateManager.addUpdateGroups([.updatePts(pts: pts, ptsCount: ptsCount)])
                            if offset == 0 {
                                return .fail(true)
                            } else {
                                return .complete()
                            }
                        }
                    } else {
                        return .fail(true)
                    }
            }
            return (signal |> restart)
                |> `catch` { success -> Signal<Void, NoError> in
                    if success {
                        return account.postbox.transaction { transaction -> Void in
                            transaction.removeAllMessagesWithAuthor(peerId, authorId: memberId)
                        }
                    } else {
                        return .complete()
                    }
            }
        } else {
            return .complete()
        }
    } |> switchToLatest
}

