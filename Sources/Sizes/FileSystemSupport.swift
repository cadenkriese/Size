import Darwin
import System

func fileType(_ mode: mode_t) -> mode_t {
    mode & mode_t(S_IFMT)
}

func systemErrorDescription(_ code: Int32) -> String {
    guard let pointer = strerror(code) else { return "system error \(code)" }
    return String(cString: pointer)
}

extension FilePath {
    var lossyString: String {
        withPlatformString { pointer in
            let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
            return String(decodingCString: bytes, as: UTF8.self)
        }
    }
}
