import Foundation
#if os(macOS)
    import PostboxMac
    import SwiftSignalKitMac
#else
    import Postbox
    import SwiftSignalKit
#endif

extension StickerPackReference {
    init(_ stickerPackInfo: StickerPackCollectionInfo) {
        self = .id(id: stickerPackInfo.id.id, accessHash: stickerPackInfo.accessHash)
    }
    
    var apiInputStickerSet: Api.InputStickerSet {
        switch self {
            case let .id(id, accessHash):
                return .inputStickerSetID(id: id, accessHash: accessHash)
            case let .name(name):
                return .inputStickerSetShortName(shortName: name)
        }
    }
}

public enum LoadedStickerPack {
    case fetching
    case none
    case result(info: StickerPackCollectionInfo, items: [ItemCollectionItem], installed: Bool)
}

func remoteStickerPack(network: Network, reference: StickerPackReference) -> Signal<(StickerPackCollectionInfo, [ItemCollectionItem])?, NoError> {
    return network.request(Api.functions.messages.getStickerSet(stickerset: reference.apiInputStickerSet))
        |> map { Optional($0) }
        |> `catch` { _ -> Signal<Api.messages.StickerSet?, NoError> in
            return .single(nil)
        }
        |> map { result -> (StickerPackCollectionInfo, [ItemCollectionItem])? in
            guard let result = result else {
                return nil
            }
            
            let info: StickerPackCollectionInfo
            var items: [ItemCollectionItem] = []
            switch result {
            case let .stickerSet(set, packs, documents):
                let namespace: ItemCollectionId.Namespace
                switch set {
                    case let .stickerSet(flags, _, _, _, _, _, _, _):
                        if (flags & (1 << 3)) != 0 {
                            namespace = Namespaces.ItemCollection.CloudMaskPacks
                        } else {
                            namespace = Namespaces.ItemCollection.CloudStickerPacks
                        }
                }
                info = StickerPackCollectionInfo(apiSet: set, namespace: namespace)
                var indexKeysByFile: [MediaId: [MemoryBuffer]] = [:]
                for pack in packs {
                    switch pack {
                    case let .stickerPack(text, fileIds):
                        let key = ValueBoxKey(text).toMemoryBuffer()
                        for fileId in fileIds {
                            let mediaId = MediaId(namespace: Namespaces.Media.CloudFile, id: fileId)
                            if indexKeysByFile[mediaId] == nil {
                                indexKeysByFile[mediaId] = [key]
                            } else {
                                indexKeysByFile[mediaId]!.append(key)
                            }
                        }
                    }
                }
                
                for apiDocument in documents {
                    if let file = telegramMediaFileFromApiDocument(apiDocument), let id = file.id {
                        let fileIndexKeys: [MemoryBuffer]
                        if let indexKeys = indexKeysByFile[id] {
                            fileIndexKeys = indexKeys
                        } else {
                            fileIndexKeys = []
                        }
                        items.append(StickerPackItem(index: ItemCollectionItemIndex(index: Int32(items.count), id: id.id), file: file, indexKeys: fileIndexKeys))
                    }
                }
            }
            
            return (info, items)
        }
}

public func loadedStickerPack(postbox: Postbox, network: Network, reference: StickerPackReference) -> Signal<LoadedStickerPack, NoError> {
    return cachedStickerPack(postbox: postbox, network: network, reference: reference)
        |> map { result -> LoadedStickerPack in
            switch result {
                case .none:
                    return .none
                case .fetching:
                    return .fetching
                case let .result(info, items, installed):
                    return .result(info: info, items: items, installed: installed)
            }
        }
}
