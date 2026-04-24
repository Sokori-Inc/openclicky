//
//  ClaudeAgentSDKAPI.swift
//  OpenClicky
//
//  Local Claude Agent SDK bridge. This runs the user's installed Claude runtime
//  and lets Claude Code/Agent SDK own authentication instead of reading tokens.
//

import Foundation

final class ClaudeAgentSDKAPI {
    private let executableURL: URL
    private let fileManager: FileManager
    private let workingDirectory: URL
    var model: String

    init?(
        model: String = OpenClickyModelCatalog.defaultVoiceResponseModelID,
        fileManager: FileManager = .default,
        workingDirectory: URL? = nil
    ) {
        guard let executableURL = Self.findExecutable(fileManager: fileManager) else {
            return nil
        }

        self.executableURL = executableURL
        self.fileManager = fileManager
        self.workingDirectory = workingDirectory ?? fileManager.homeDirectoryForCurrentUser
        self.model = model
    }

    static func findExecutable(fileManager: FileManager = .default) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let explicitPath = environment["OPENCLICKY_CLAUDE_EXECUTABLE"],
           let executable = executableURL(atPath: explicitPath, fileManager: fileManager) {
            return executable
        }

        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("claude", isDirectory: false) }

        let fixedCandidates = [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude", isDirectory: false),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude", isDirectory: false),
            URL(fileURLWithPath: "/usr/local/bin/claude", isDirectory: false)
        ]

        return (pathCandidates + fixedCandidates).first { candidate in
            fileManager.isExecutableFile(atPath: candidate.path)
        }
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startedAt = Date()
        let temporaryDirectory = try makeTemporaryDirectory()
        defer {
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        let attachments = try writeImageAttachments(images, to: temporaryDirectory)
        let prompt = Self.composePrompt(
            userPrompt: userPrompt,
            conversationHistory: conversationHistory,
            attachments: attachments
        )

        let output = try await runClaudeAgent(
            prompt: prompt,
            systemPrompt: systemPrompt,
            attachmentDirectory: temporaryDirectory
        )
        let text = Self.extractText(from: output.stdout)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(
                domain: "ClaudeAgentSDKAPI",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Claude Agent SDK returned an empty response."]
            )
        }

        await MainActor.run {
            onTextChunk(text)
        }
        return (text: text, duration: Date().timeIntervalSince(startedAt))
    }

    private static func executableURL(atPath path: String, fileManager: FileManager) -> URL? {
        let expandedPath = (path as NSString).expandingTildeInPath
        guard fileManager.isExecutableFile(atPath: expandedPath) else { return nil }
        return URL(fileURLWithPath: expandedPath, isDirectory: false)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("OpenClickyClaudeAgent", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeImageAttachments(
        _ images: [(data: Data, label: String)],
        to directory: URL
    ) throws -> [(label: String, fileURL: URL)] {
        try images.enumerated().map { index, image in
            let fileExtension = image.data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : "jpg"
            let fileURL = directory.appendingPathComponent("screen-\(index + 1).\(fileExtension)", isDirectory: false)
            try image.data.write(to: fileURL, options: [.atomic])
            return (label: image.label, fileURL: fileURL)
        }
    }

    private static func composePrompt(
        userPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        attachments: [(label: String, fileURL: URL)]
    ) -> String {
        var sections: [String] = []

        if !conversationHistory.isEmpty {
            var lines = ["Recent conversation:"]
            for entry in conversationHistory {
                lines.append("User: \(entry.userPlaceholder)")
                lines.append("OpenClicky: \(entry.assistantResponse)")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        if !attachments.isEmpty {
            var lines = [
                "Screen context:",
                "Use the Read tool on these local image files when screen details matter. Return pointing tags in screenshot pixel coordinates when appropriate."
            ]
            for (index, attachment) in attachments.enumerated() {
                lines.append("\(index + 1). \(attachment.label): \(attachment.fileURL.path)")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        sections.append("User request:\n\(userPrompt)")
        return sections.joined(separator: "\n\n")
    }

    private func runClaudeAgent(
        prompt: String,
        systemPrompt: String,
        attachmentDirectory: URL
    ) async throws -> (stdout: String, stderr: String) {
        let arguments = [
            "-p",
            "--output-format", "stream-json",
            "--permission-mode", "dontAsk",
            "--model", model,
            "--system-prompt", systemPrompt,
            "--allowedTools", "Read",
            "--add-dir", attachmentDirectory.path,
            prompt
        ]

        return try await Self.runProcess(
            executableURL: executableURL,
            arguments: arguments,
            workingDirectory: workingDirectory
        )
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL
    ) async throws -> (stdout: String, stderr: String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let outputPipe = Pipe()
                let errorPipe = Pipe()

                process.executableURL = executableURL
                process.arguments = arguments
                process.currentDirectoryURL = workingDirectory
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                process.environment = ProcessInfo.processInfo.environment

                do {
                    try process.run()
                    process.waitUntilExit()

                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let stdout = String(data: outputData, encoding: .utf8) ?? ""
                    let stderr = String(data: errorData, encoding: .utf8) ?? ""

                    guard process.terminationStatus == 0 else {
                        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stdout : stderr
                        throw NSError(
                            domain: "ClaudeAgentSDKAPI",
                            code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: message]
                        )
                    }

                    continuation.resume(returning: (stdout: stdout, stderr: stderr))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func extractText(from stdout: String) -> String {
        var assistantTextParts: [String] = []
        var resultText: String?

        for line in stdout.components(separatedBy: .newlines) {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if let type = json["type"] as? String,
               type == "result",
               let text = json["result"] as? String,
               !text.isEmpty {
                resultText = text
            }

            guard let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else {
                continue
            }

            for block in content {
                if let type = block["type"] as? String,
                   type == "text",
                   let text = block["text"] as? String,
                   !text.isEmpty {
                    assistantTextParts.append(text)
                }
            }
        }

        if let resultText, !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return resultText
        }

        let assistantText = assistantTextParts.joined()
        if !assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return assistantText
        }

        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
