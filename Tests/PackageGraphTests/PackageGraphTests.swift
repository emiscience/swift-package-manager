/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import XCTest

import Basic
@testable import PackageGraph
import PackageDescription
import PackageDescription4
import PackageModel
import TestSupport
import enum PackageLoading.ModuleError

class PackageGraphTests: XCTestCase {

    func testBasic() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/Foo/Sources/Foo/source.swift",
            "/Foo/Sources/FooDep/source.swift",
            "/Foo/Tests/FooTests/source.swift",
            "/Bar/source.swift",
            "/Baz/source.swift",
            "/Baz/Tests/BazTests/source.swift"
        )

        let diagnostics = DiagnosticsEngine()
        let g = loadMockPackageGraph([
            "/Foo": Package(name: "Foo", targets: [Target(name: "Foo", dependencies: ["FooDep"])]),
            "/Bar": Package(name: "Bar", dependencies: [.Package(url: "/Foo", majorVersion: 1)]),
            "/Baz": Package(name: "Baz", dependencies: [.Package(url: "/Bar", majorVersion: 1)]),
        ], root: "/Baz", diagnostics: diagnostics, in: fs)

        PackageGraphTester(g) { result in
            result.check(packages: "Bar", "Foo", "Baz")
            result.check(targets: "Bar", "Foo", "Baz", "FooDep")
            result.check(testModules: "BazTests", "FooTests")
            result.check(dependencies: "FooDep", target: "Foo")
            result.check(dependencies: "Foo", target: "Bar")
            result.check(dependencies: "Bar", target: "Baz")
        }
    }

    func testProductDependencies() throws {
        typealias Package = PackageDescription4.Package

        let fs = InMemoryFileSystem(emptyFiles:
            "/Foo/Sources/Foo/source.swift",
            "/Bar/Source/Bar/source.swift"
        )

        let diagnostics = DiagnosticsEngine()
        let g = loadMockPackageGraph4([
            "/Bar": Package(
                name: "Bar",
                products: [
                    .library(name: "Bar", targets: ["Bar"]),
                ],
                targets: [
                    .target(name: "Bar"),
                ]),
            "/Foo": .init(
                name: "Foo",
                dependencies: [
                    .package(url: "/Bar", from: "1.0.0"),
                ],
                targets: [
                    .target(name: "Foo", dependencies: ["Bar"]),
                ]),
        ], root: "/Foo", diagnostics: diagnostics, in: fs)

        PackageGraphTester(g) { result in
            result.check(packages: "Bar", "Foo")
            result.check(targets: "Bar", "Foo")
            result.check(dependencies: "Bar", target: "Foo")
        }
    }

    func testCycle() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/Foo/source.swift",
            "/Bar/source.swift",
            "/Baz/source.swift"
        )

        let diagnostics = DiagnosticsEngine()
        _ = loadMockPackageGraph([
            "/Foo": Package(name: "Foo", dependencies: [.Package(url: "/Bar", majorVersion: 1)]),
            "/Bar": Package(name: "Bar", dependencies: [.Package(url: "/Baz", majorVersion: 1)]),
            "/Baz": Package(name: "Baz", dependencies: [.Package(url: "/Bar", majorVersion: 1)]),
        ], root: "/Foo", diagnostics: diagnostics, in: fs)

        XCTAssertEqual(diagnostics.diagnostics[0].localizedDescription, "cyclic dependency declaration found: Foo -> Bar -> Baz -> Bar")
    }

    // Make sure there is no error when we reference Test targets in a package and then
    // use it as a dependency to another package. SR-2353
    func testTestTargetDeclInExternalPackage() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/Foo/source.swift",
            "/Foo/Tests/SomeTests/source.swift",
            "/Bar/source.swift",
            "/Bar/Tests/BarTests/source.swift"
        )

        let g = loadMockPackageGraph([
            "/Foo": Package(name: "Foo", targets: [Target(name: "SomeTests", dependencies: ["Foo"])]),
            "/Bar": Package(name: "Bar", dependencies: [.Package(url: "/Foo", majorVersion: 1)]),
        ], root: "/Bar", in: fs)

        PackageGraphTester(g) { result in
            result.check(packages: "Bar", "Foo")
            result.check(targets: "Bar", "Foo")
            result.check(testModules: "BarTests", "SomeTests")
        }
    }

    func testDuplicateModules() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/Foo/Sources/Bar/source.swift",
            "/Bar/source.swift"
        )

        let diagnostics = DiagnosticsEngine()
        _ = loadMockPackageGraph([
            "/Foo": Package(name: "Foo"),
            "/Bar": Package(name: "Bar", dependencies: [.Package(url: "/Foo", majorVersion: 1)]),
        ], root: "/Bar", diagnostics: diagnostics, in: fs)

        XCTAssertEqual(diagnostics.diagnostics[0].localizedDescription, "multiple targets named 'Bar'")
    }

    func testEmptyDependency() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/Foo/Sources/Foo/foo.swift",
            "/Bar/Sources/Bar/source.txt"
        )

        let diagnostics = DiagnosticsEngine()
        _ = loadMockPackageGraph4([
            "/Bar": Package(
                name: "Bar",
                products: [
                    .library(name: "Bar", targets: ["Bar"]),
                ],
                targets: [
                    .target(name: "Bar"),
                ]),
            "/Foo": .init(
                name: "Foo",
                dependencies: [
                    .package(url: "/Bar", from: "1.0.0"),
                ],
                targets: [
                    .target(name: "Foo", dependencies: ["Bar"]),
                ]),
            ], root: "/Foo", diagnostics: diagnostics, in: fs)

        DiagnosticsEngineTester(diagnostics) { result in
            result.check(diagnostic: "target 'Bar' in package 'Bar' contains no valid source files", behavior: .warning)
            result.check(diagnostic: "target 'Bar' referenced in product 'Bar' could not be found", behavior: .error, location: "'Bar' /Bar")
            result.check(diagnostic: "product dependency 'Bar' not found", behavior: .error, location: "'Foo' /Foo")

        }
    }

    func testUnusedDependency() throws {
        let fs = InMemoryFileSystem(emptyFiles:
            "/Foo/Sources/Foo/foo.swift",
            "/Bar/Sources/Bar/bar.swift",
            "/Baz/Sources/Baz/baz.swift",
            "/Biz/Sources/Biz/main.swift"
        )

        let diagnostics = DiagnosticsEngine()
        _ = loadMockPackageGraph4([
            "/Bar": Package(
                name: "Bar",
                products: [
                    .library(name: "BarLibrary", targets: ["Bar"]),
                ],
                targets: [
                    .target(name: "Bar"),
                ]),
            "/Baz": Package(
                name: "Baz",
                products: [
                    .library(name: "BazLibrary", targets: ["Baz"]),
                ],
                targets: [
                    .target(name: "Baz"),
                ]),
            "/Biz": Package(
                name: "Biz",
                products: [
                    .executable(name: "biz", targets: ["Biz"]),
                ],
                targets: [
                    .target(name: "Biz"),
                ]),
            "/Foo": .init(
                name: "Foo",
                dependencies: [
                    .package(url: "/Bar", from: "1.0.0"),
                    .package(url: "/Baz", from: "1.0.0"),
                    .package(url: "/Biz", from: "1.0.0"),
                ],
                targets: [
                    .target(name: "Foo", dependencies: ["BarLibrary"]),
                ]),
            ], root: "/Foo", diagnostics: diagnostics, in: fs)

        DiagnosticsEngineTester(diagnostics) { result in
            result.check(diagnostic: "dependency 'Baz' is not used by any target", behavior: .warning)
        }
    }

    static var allTests = [
        ("testBasic", testBasic),
        ("testDuplicateModules", testDuplicateModules),
        ("testCycle", testCycle),
        ("testProductDependencies", testProductDependencies),
        ("testTestTargetDeclInExternalPackage", testTestTargetDeclInExternalPackage),
        ("testEmptyDependency", testEmptyDependency),
        ("testUnusedDependency", testUnusedDependency),
    ]
}
