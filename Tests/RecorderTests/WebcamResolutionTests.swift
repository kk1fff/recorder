import XCTest
@testable import Recorder

final class WebcamResolutionTests: XCTestCase {
    func testAutoIsDefaultAndCameraOnlyUses720p() {
        XCTAssertEqual(CaptureEngine().webcamResolution, .auto)
        XCTAssertEqual(WebcamResolution.auto.size(screenSize: nil), CGSize(width: 1280, height: 720))
    }

    func testAutoSizesRelativeToActualScreenWidth() {
        for screen in [CGSize(width: 1920, height: 1080), CGSize(width: 1280, height: 720), CGSize(width: 600, height: 1000)] {
            let camera = WebcamResolution.auto.size(screenSize: screen)
            XCTAssertEqual(camera.width / (screen.width + camera.width), 0.1, accuracy: 0.002)
            XCTAssertEqual(camera.height, camera.width * 9 / 16, accuracy: 1)
            XCTAssertEqual(camera.width.truncatingRemainder(dividingBy: 2), 0)
            XCTAssertEqual(camera.height.truncatingRemainder(dividingBy: 2), 0)
        }
        XCTAssertEqual(WebcamResolution.auto.size(screenSize: CGSize(width: 1920, height: 1080)), CGSize(width: 214, height: 120))
        XCTAssertEqual(WebcamResolution.auto.size(screenSize: CGSize(width: 2, height: 2)), CGSize(width: 2, height: 2))
    }

    func testFixedPresetsIgnoreScreenSize() {
        for screen in [nil, CGSize(width: 1920, height: 1080)] {
            XCTAssertEqual(WebcamResolution.p480.size(screenSize: screen), CGSize(width: 854, height: 480))
            XCTAssertEqual(WebcamResolution.p720.size(screenSize: screen), CGSize(width: 1280, height: 720))
        }
    }
}
