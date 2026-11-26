/// `REQUESTED_VIDEO_*` / `REQUESTED_GROUP_VIDEO_*` / `REQUESTED_SCREEN_SHARE_*` (ts/calling/constants).
public enum CallVideoConstants {
    public static let direct = (width: 960, height: 720, framerate: 30)
    public static let group = (width: 640, height: 480, framerate: 30)
    public static let screenShare = (width: 2880, height: 1800, framerate: 5)
    /// `MAX_FRAME_WIDTH` / `MAX_FRAME_HEIGHT`: remote frames larger than this are dropped.
    public static let maxFrame = (width: 2880, height: 1800)
}

extension CapturedFrame {
    /// The frame as I420 planes for the local preview (VideoRenderer); limited range.
    public var planes: VideoPlanes {
        let ySize = width * height, cw = width / 2, ch = height / 2
        var u = [UInt8](repeating: 0, count: cw * ch), v = u
        var i = 0
        for k in 0..<(cw * ch) {
            u[k] = nv12[ySize + i]
            v[k] = nv12[ySize + i + 1]
            i += 2
        }
        return VideoPlanes(width: width, height: height, y: Array(nv12[0..<ySize]), u: u, v: v, fullRange: false, matrix: 2, time: 0)
    }
}
