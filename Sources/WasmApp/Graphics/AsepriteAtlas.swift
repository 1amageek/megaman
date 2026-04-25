import Foundation

// Aseprite "Array" JSON export format (v1.3-beta14).
// `meta.frameTags` groups the flat `frames[]` list into named animations.

struct AsepriteAtlas: Decodable {
    struct Frame: Decodable {
        struct Rect: Decodable {
            let x: Int
            let y: Int
            let w: Int
            let h: Int
        }
        let filename: String
        let frame: Rect
        let duration: Int   // milliseconds
    }

    struct Meta: Decodable {
        struct Size: Decodable {
            let w: Int
            let h: Int
        }
        struct FrameTag: Decodable {
            let name: String
            let from: Int
            let to: Int
            let direction: String
        }
        let image: String
        let size: Size
        let frameTags: [FrameTag]
    }

    let frames: [Frame]
    let meta: Meta

    static func decode(from data: Data) throws -> AsepriteAtlas {
        try JSONDecoder().decode(AsepriteAtlas.self, from: data)
    }
}
