import Foundation
import LavaEditorExtensionAPI
@_implementationOnly import SwiftParser
@_implementationOnly import SwiftSyntax

struct DiscoveredSwiftTest {
    let line: UInt32
    let name: String
    let swiftTesting: Bool
}

@_implementationOnly private final class TestVisitor: SyntaxVisitor {
    var cases: [DiscoveredSwiftTest] = []
    let positions: SourceLocationConverter

    init(source: SourceFileSyntax) {
        positions = SourceLocationConverter(fileName: "", tree: source)
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let attribute = node.attributes.compactMap { $0.as(AttributeSyntax.self) }.first {
            ["Test", "Testing.Test"].contains($0.attributeName.trimmedDescription)
        }
        var names: [String] = []
        var xctest = false
        var ancestor = node.parent
        while let scope = ancestor {
            if let type = scope.as(ClassDeclSyntax.self) {
                xctest = xctest || type.inheritanceClause?.inheritedTypes.contains {
                    ["XCTestCase", "XCTest.XCTestCase"].contains($0.type.trimmedDescription)
                } == true
                names.append(type.name.text)
            } else if let type = scope.as(StructDeclSyntax.self) { names.append(type.name.text) }
            else if let type = scope.as(EnumDeclSyntax.self) { names.append(type.name.text) }
            else if let type = scope.as(ActorDeclSyntax.self) { names.append(type.name.text) }
            else if let type = scope.as(ExtensionDeclSyntax.self) {
                names += type.extendedType.trimmedDescription.components(separatedBy: ".").reversed()
            }
            ancestor = scope.parent
        }
        let parameters = node.signature.parameterClause.parameters
        let swiftTesting = attribute != nil
        var name = node.name.text.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        if swiftTesting {
            name += "(" + parameters.map { $0.firstName.text + ":" }.joined() + ")"
        } else {
            guard xctest, name.hasPrefix("test"), parameters.isEmpty,
                  !node.modifiers.contains(where: { ["static", "class"].contains($0.name.text) })
            else { return .skipChildren }
        }
        let qualified = (names.reversed() + [name]).joined(separator: "/")
        let anchor = attribute?.positionAfterSkippingLeadingTrivia ?? node.funcKeyword.positionAfterSkippingLeadingTrivia
        let line = positions.location(for: anchor).line
        cases.append(DiscoveredSwiftTest(line: UInt32(line - 1), name: qualified, swiftTesting: swiftTesting))
        return .skipChildren
    }
}

func discoverSwiftTests(in text: String) -> [DiscoveredSwiftTest] {
    let source = Parser.parse(source: text)
    let visitor = TestVisitor(source: source)
    visitor.walk(source)
    return visitor.cases
}

private struct ToolError: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

private func packageRoot(for file: URL) -> URL? {
    var dir = file.deletingLastPathComponent()
    while dir.path != "/" {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { return dir }
        dir.deleteLastPathComponent()
    }
    return nil
}

private func swift(_ arguments: [String], in directory: URL, captureLimit: Int = 4 << 20) throws -> (Int32, String) {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    child.arguments = ["swift"] + arguments
    child.currentDirectoryURL = directory
    let pipe = Pipe()
    child.standardOutput = pipe
    // Package descriptions are JSON. Keep compiler warnings out of that stream.
    if arguments.first == "test" { child.standardError = pipe }
    try child.run()
    var output = Data()
    while let chunk = try pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
        output.append(chunk)
        if output.count > captureLimit { output.removeFirst(output.count - captureLimit) }
    }
    child.waitUntilExit()
    return (child.terminationStatus, String(decoding: output, as: UTF8.self))
}

private struct PackageInfo: Decodable {
    struct Target: Decodable {
        let type: String
        let c99name: String?
        let path: String?
        let sources: [String]?
    }
    let targets: [Target]
}

private func run(_ test: DiscoveredSwiftTest, document: ActionDocument, root: URL) throws -> String {
    let file = URL(fileURLWithPath: document.path).standardizedFileURL
    guard try Data(contentsOf: file).elementsEqual(document.text.utf8) else {
        throw ToolError(text: "The file changed on disk. Save or reload it before running the test.")
    }
    let (status, json) = try swift(["package", "describe", "--type", "json"], in: root)
    guard status == 0 else { throw ToolError(text: "Could not read the Swift package description.") }
    let package = try JSONDecoder().decode(PackageInfo.self, from: Data(json.utf8))
    let targets = package.targets.filter { target in
        guard target.type == "test", let path = target.path else { return false }
        return target.sources?.contains(where: {
            root.appendingPathComponent(path).appendingPathComponent($0).standardizedFileURL == file
        }) == true
    }
    guard targets.count == 1, let module = targets.first?.c99name else { throw ToolError(text: "This file must belong to one SwiftPM test target.") }
    let identifier = module + "." + test.name
    let (listed, listing) = try swift(["test", "list"], in: root)
    guard listed == 0 else { throw ToolError(text: "Test build failed. " + diagnostic(listing)) }
    guard listing.split(whereSeparator: \.isNewline).filter({ $0 == identifier }).count == 1 else {
        throw ToolError(text: "SwiftPM did not discover one test named " + identifier)
    }
    let filter = "^" + NSRegularExpression.escapedPattern(for: identifier) + (test.swiftTesting ? "($|/)" : "$")
    let (code, log) = try swift(["test", "--skip-build", "--filter", filter], in: root, captureLimit: 65536)
    if code != 0 { return "Failed: " + test.name + " · " + diagnostic(log) }
    if log.contains("No matching test cases were run") { return "No matching test: " + test.name }
    if log.contains("skipped") && !log.contains("passed after") { return "Skipped: " + test.name }
    return "Passed: " + test.name
}

private func diagnostic(_ output: String) -> String {
    let lines = output.split(whereSeparator: \.isNewline)
    let line = lines.last(where: { $0.contains("error:") || $0.contains("Expectation failed") || $0.contains("XCTAssert") })
        ?? lines.last
    return String((line ?? "See SwiftPM output").prefix(420))
}

@_cdecl("lava_editor_activate_v1")
public func activate(_ command: UnsafePointer<CChar>, _ reference: UnsafePointer<CChar>, _ invocation: UInt64) -> Int32 {
    guard String(cString: command) == "tests" else { return 2 }
    return runDocumentActionProvider(reference) { editor in
        let document = try await editor.readDocument(invocation: invocation)
        let root = document.path.isEmpty ? nil : packageRoot(for: URL(fileURLWithPath: document.path))
        let tests = root == nil ? [] : discoverSwiftTests(in: document.text)
        if document.actionId.isEmpty {
            let actions = tests.map { DocumentLineAction(line: $0.line, id: $0.name, gutterPlay: true, hint: "Run") }
            guard try await editor.setLineActions(invocation: invocation, actions: actions) else { throw ToolError(text: "Actions rejected") }
        } else {
            let message: String
            do {
                guard let root, let test = tests.first(where: { $0.name == document.actionId }) else {
                    throw ToolError(text: "This test is no longer available.")
                }
                message = try run(test, document: document, root: root)
            } catch { message = error.localizedDescription }
            _ = try await editor.reportResult(invocation: invocation, message: message)
        }
    }
}
