#!/usr/bin/env swift
import Foundation

// `make links`, which CI's lint job runs on every pull request: every relative
// link in the repository's Markdown, and every #anchor in one, resolves inside
// the checkout, the file or folder it names existing and the heading or
// explicit anchor it names being in that file. Every tracked Markdown file is
// read, not only the changed ones, so renaming a heading or moving a doc
// fails wherever it was linked from. It reads nothing but the checkout: a link
// with a scheme, such as https: or mailto:, is left alone, so the check needs
// no network and cannot flake. Code blocks and code spans are skipped, and an
// anchor is a heading's slug as GitHub makes it, lowercased, with punctuation
// dropped, spaces as hyphens and -1, -2 on repeats, or an id or name attribute.
//
// Usage: scripts/check-links.swift [<file.md> ...]
//   <file.md>  check only these files; every tracked Markdown file by default
// Exit: 0 every link resolves, 1 some do not, 2 the files could not be read.

let root = URL(fileURLWithPath: CommandLine.arguments[0])
  .deletingLastPathComponent()  // scripts
  .deletingLastPathComponent()  // the repository
  .standardizedFileURL

func trackedMarkdown() -> [String] {
  let git = Process()
  git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  git.arguments = ["git", "-C", root.path, "ls-files", "-z", "--", "*.md"]
  let pipe = Pipe()
  git.standardOutput = pipe
  do { try git.run() } catch {
    FileHandle.standardError.write(Data("links: could not run git: \(error)\n".utf8))
    exit(2)
  }
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  git.waitUntilExit()
  guard git.terminationStatus == 0 else { exit(2) }
  return String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
}

func matches(_ pattern: String, in text: String) -> [[String]] {
  let expression = try! NSRegularExpression(pattern: pattern)
  let range = NSRange(text.startIndex..., in: text)
  return expression.matches(in: text, range: range).map { match in
    (0..<match.numberOfRanges).map { index in
      Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
    }
  }
}

/// A file's lines outside fenced code blocks, each with its number, as it
/// stands and with its code spans blanked out.
func prose(of text: String) -> [(number: Int, raw: String, line: String)] {
  var fence: String?
  var lines: [(Int, String, String)] = []
  for (index, line) in text.components(separatedBy: "\n").enumerated() {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if let open = fence {
      if trimmed.hasPrefix(open) { fence = nil }
      continue
    }
    if let marker = matches(#"^(`{3,}|~{3,})"#, in: trimmed).first?[1] {
      fence = marker
      continue
    }
    let spans = try! NSRegularExpression(pattern: #"(`+)(?:(?!\1).)+?\1"#)
    let blanked = spans.stringByReplacingMatches(
      in: line,
      range: NSRange(line.startIndex..., in: line),
      withTemplate: ""
    )
    lines.append((index + 1, line, blanked))
  }
  return lines
}

/// The anchors GitHub gives a Markdown file: each heading's slug, numbered on
/// repeats, and every id or name attribute.
func anchors(of text: String) -> Set<String> {
  var found: Set<String> = []
  var seen: [String: Int] = [:]
  for (_, raw, line) in prose(of: text) {
    if let heading = matches(#"^ {0,3}#{1,6}\s+(.*?)\s*#*\s*$"#, in: raw).first?[1] {
      var visible = heading
      // A code span, a link or an image shows its text; emphasis and tags
      // show nothing.
      visible = visible.replacingOccurrences(
        of: #"!?\[([^\]]*)\]\([^)]*\)"#,
        with: "$1",
        options: .regularExpression
      )
      visible = visible.replacingOccurrences(
        of: #"<[^>]+>"#,
        with: "",
        options: .regularExpression
      )
      let slug = String(
        visible.lowercased().unicodeScalars.compactMap { scalar -> Character? in
          if scalar == " " { return "-" }
          if scalar == "-" || scalar == "_" { return Character(scalar) }
          if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
            || CharacterSet.nonBaseCharacters.contains(scalar)
          {
            return Character(scalar)
          }
          return nil
        }
      )
      let count = seen[slug, default: 0]
      seen[slug] = count + 1
      found.insert(count == 0 ? slug : "\(slug)-\(count)")
    }
    for match in matches(#"<[^>]*\s(?:id|name)\s*=\s*["']([^"']+)["']"#, in: line) {
      found.insert(match[1])
    }
  }
  return found
}

var anchorCache: [String: Set<String>] = [:]
func anchors(inFile path: String) -> Set<String>? {
  if let cached = anchorCache[path] { return cached }
  guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
  let found = anchors(of: text)
  anchorCache[path] = found
  return found
}

/// Why a link's target does not resolve from `file`, or nil
/// when it does.
func problem(with rawTarget: String, from file: String) -> String? {
  var target = rawTarget.trimmingCharacters(in: .whitespaces)
  if target.hasPrefix("<"), target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
  if target.isEmpty { return "an empty link" }
  // A scheme, such as https: or mailto:, is outside the checkout.
  if target.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil
    || target.hasPrefix("//")
  {
    return nil
  }
  let parts = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
  var path = String(parts[0])
  if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
  path = path.removingPercentEncoding ?? path
  let anchor =
    parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : nil

  let base = root.appendingPathComponent(file).deletingLastPathComponent()
  let resolved: URL
  if path.isEmpty {
    resolved = root.appendingPathComponent(file)
  } else if path.hasPrefix("/") {
    resolved = root.appendingPathComponent(String(path.dropFirst()))
  } else {
    resolved = base.appendingPathComponent(path)
  }
  let standardized = resolved.standardizedFileURL
  guard standardized.path == root.path || standardized.path.hasPrefix(root.path + "/") else {
    return "\(path) is outside the repository"
  }
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory) else {
    return "\(path) does not exist"
  }
  guard let anchor, !anchor.isEmpty, !isDirectory.boolValue,
    standardized.pathExtension.lowercased() == "md"
  else { return nil }
  guard let found = anchors(inFile: standardized.path) else {
    return "\(path) could not be read"
  }
  if found.contains(anchor) || found.contains(anchor.lowercased()) { return nil }
  let name = path.isEmpty ? "this file" : path
  return "\(name) has no heading or anchor #\(anchor)"
}

let files =
  CommandLine.arguments.count > 1 ? Array(CommandLine.arguments.dropFirst()) : trackedMarkdown()
var broken = 0
var links = 0
for file in files {
  guard let text = try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
  else {
    FileHandle.standardError.write(Data("links: could not read \(file)\n".utf8))
    exit(2)
  }
  for (number, _, line) in prose(of: text) {
    // Inline links and images, [text](target "title"), and reference
    // definitions, [label]: target.
    var targets = matches(
      #"\]\(\s*(<[^>]*>|[^\s)]+)(?:\s+(?:"[^"]*"|'[^']*'|\([^)]*\)))?\s*\)"#,
      in: line
    )
    .map { $0[1] }
    targets += matches(#"^ {0,3}\[[^\]]+\]:\s+(<[^>]*>|\S+)"#, in: line).map { $0[1] }
    targets += matches(#"<(?:a|img)\s[^>]*(?:href|src)\s*=\s*["']([^"']+)["']"#, in: line).map {
      $0[1]
    }
    for target in targets {
      links += 1
      if let problem = problem(with: target, from: file) {
        broken += 1
        FileHandle.standardError.write(Data("\(file):\(number): \(problem)\n".utf8))
      }
    }
  }
}

if broken == 0 {
  print("links: passed, \(links) links in \(files.count) files")
} else {
  FileHandle.standardError.write(
    Data("links: failed, \(broken) of \(links) links in \(files.count) files do not resolve\n".utf8)
  )
  exit(1)
}
