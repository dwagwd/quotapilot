import XCTest
@testable import UsageCore

final class CLIArgumentsTests: XCTestCase {
    func testOptionValuesAreNotPositional() {
        XCTAssertEqual(CLIArguments.positional(["route", "--hours", "6", "review"]), ["route", "review"])
        XCTAssertEqual(CLIArguments.positional(["--hours", "6", "route", "review", "--json"]), ["route", "review"])
        XCTAssertEqual(CLIArguments.positional(["--only", "speed", "share"]), ["share"])
        XCTAssertEqual(CLIArguments.positional(["watch", "--interval", "30"]), ["watch"])
        XCTAssertEqual(CLIArguments.positional(["share", "--only", "speed,quota", "--hours", "12", "--yes"]), ["share"])
    }

    func testFlagsWithoutValuesAndHelp() {
        XCTAssertEqual(CLIArguments.positional([]), [])
        XCTAssertEqual(CLIArguments.positional(["--json"]), [])
        XCTAssertEqual(CLIArguments.positional(["-h"]), ["-h"])
        XCTAssertEqual(CLIArguments.positional(["status", "--hours"]), ["status"])
    }
}
