import Foundation

extension Data {
    func u8(at offset: Int) -> UInt8 {
        self[offset]
    }

    func u16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func i16LE(at offset: Int) -> Int16 {
        Int16(bitPattern: u16LE(at: offset))
    }

    func u32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func i32LE(at offset: Int) -> Int32 {
        Int32(bitPattern: u32LE(at: offset))
    }

    func f32LE(at offset: Int) -> Float {
        Float(bitPattern: u32LE(at: offset))
    }
}

@inline(__always)
func appendBounded<T>(_ array: inout [T], _ value: T, maxCount: Int) {
    array.append(value)
    let overflow = array.count - maxCount
    if overflow > 0 {
        array.removeFirst(overflow)
    }
}
