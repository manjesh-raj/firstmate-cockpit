// Manjesh Grand Line - native macOS app.
//
// Permanent self-test for the Log / Output Analyzer's pure-logic layer
// (`fm/grandline-log-analyzer-build`), run via
// `FM_RUN_LOG_ANALYZER_TESTS=1 .build/debug/FirstmateCockpit` - the same
// convention as `DocsRunbookDataSelfTest.swift`/`ShiftGitSyncSelfTest.swift`.
//
// Everything here runs against scratch temp directories and, where a
// `claude` process is genuinely needed, against a disposable fake `claude`
// shell script via `LogAnalyzerAI.claudePathOverrideForTests` (the same
// test-only seam `DictationCleanupSelfTest`/`SRELeadPostmortemSelfTest`
// already use). It never touches the captain's real git-synced
// `personal-tasks/` clone, never calls the real `claude`, and never reaches
// any infrastructure.
//
// **The two checks that actually matter are the byte-level ones.** Sections
// 1 and 9 do not reason about call ordering to conclude that secrets are
// safe - they plant real secret values in the input, then grep the literal
// bytes of (a) a fully-built AI prompt and (b) every file of a saved
// investigation for those values. That is the only form of this check that
// stays true if someone later reorders the pipeline.

import Foundation

enum LogAnalyzerSelfTest {

    // Planted secret values. Deliberately shaped like real credentials so
    // the detector's own patterns are what has to catch them, but they are
    // obviously fake and exist only inside this file.
    private static let fakeBearer = "eyJhbGciOiJIUzI1NiJ9.ZmFrZS1wYXlsb2Fk.c2lnbmF0dXJlLWhlcmU"
    private static let fakeDBPassword = "Tr0ub4dorAndThree"
    private static let fakeAPIKey = "sk-live-9f8a2b1c4d5e6f7a8b9c0d1e"
    private static let fakeAWSKey = "AKIAIOSFODNN7EXAMPLE"

    private static var secretsPlanted: [String] {
        [fakeBearer, fakeDBPassword, fakeAPIKey, fakeAWSKey]
    }

    private static let secretyLog = """
    2026-08-22T20:14:02Z INFO  starting search-api 2.4.1
    2026-08-22T20:14:02Z DEBUG Authorization: Bearer \(fakeBearer)
    2026-08-22T20:14:03Z DEBUG dsn=postgres://search_api:\(fakeDBPassword)@db-primary.internal:5432/search
    2026-08-22T20:14:03Z DEBUG x-api-key: \(fakeAPIKey)
    2026-08-22T20:14:03Z DEBUG aws_access_key_id = \(fakeAWSKey)
    2026-08-22T20:14:11Z ERROR readiness probe failed: connection refused on 10.244.3.17:8081
    """

    private static let kubernetesLog = """
    2026-08-22T20:14:02Z INFO  http server listening on :8080
    2026-08-22T20:14:11Z ERROR Readiness probe failed: Get "http://10.244.3.17:8081/healthz": dial tcp 10.244.3.17:8081: connect: connection refused
    2026-08-22T20:14:31Z ERROR Readiness probe failed: Get "http://10.244.3.19:8081/healthz": dial tcp 10.244.3.19:8081: connect: connection refused
    2026-08-22T20:14:45Z ERROR Readiness probe failed: Get "http://10.244.3.21:8081/healthz": dial tcp 10.244.3.21:8081: connect: connection refused
    2026-08-22T20:15:41Z Warning  BackOff  kubelet  Back-off restarting failed container
    2026-08-22T20:16:03Z ERROR HTTP 503 Service Unavailable at ingress for /search
    2026-08-22T20:24:50Z INFO  service became healthy
    """

    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        let fm = FileManager.default
        let scratch = fm.temporaryDirectory
            .appendingPathComponent("log-analyzer-selftest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        // MARK: 1. Redaction (spec §14) - the security-critical section

        do {
            let result = LogRedactor.redact(secretyLog)
            check(result.count >= 4, "every planted secret class should be detected (got \(result.count))")

            for secret in secretsPlanted {
                check(!result.text.contains(secret),
                      "redacted text must not contain the planted secret \(secret.prefix(6))…")
            }
            check(result.text.contains(LogRedactor.placeholder), "redacted text should carry the placeholder")
            // Context must survive - a redaction that eats the whole line
            // would make the output useless to read.
            check(result.text.contains("db-primary.internal"),
                  "a connection string's host must survive redaction of its password")
            check(result.text.contains("Authorization: Bearer"),
                  "an Authorization header's own name must survive redaction of its token")

            for redaction in result.redactions {
                for secret in secretsPlanted {
                    check(!redaction.maskedLine.contains(secret),
                          "a redaction record's masked line must never carry the secret")
                    check(!redaction.fingerprint.contains(secret),
                          "a redaction fingerprint must never be the secret itself")
                }
            }

            // Idempotence: re-running over already-redacted text must not
            // report the placeholders as fresh finds (the page re-detects on
            // every render, so a non-idempotent redactor would inflate the
            // count every pass).
            let second = LogRedactor.redact(result.text)
            check(second.isEmpty, "redacting already-redacted text should find nothing new (found \(second.count))")

            // Clean text must not produce false positives - a detector that
            // fires on ordinary kubectl output trains the captain to skip
            // the review step.
            check(LogRedactor.redact(kubernetesLog).isEmpty,
                  "ordinary kubectl output should produce no redactions")

            check(LogRedactor.fingerprint("short") == "5 chars",
                  "a short value should be fingerprinted by length only")
            check(!LogRedactor.fingerprint(fakeBearer).contains(fakeBearer),
                  "a fingerprint must not be reversible to the value")
        }

        // MARK: 2. Source detection (spec §3)

        do {
            check(LogSourceDetector.detect(kubernetesLog).kind == .kubernetes,
                  "kubectl-shaped output should detect as Kubernetes")
            check(LogSourceDetector.detect("Exception in thread \"main\" java.lang.NullPointerException\n\tat com.x.Y(Y.java:12)").kind == .stackTrace,
                  "a Java stack trace should detect as a stack trace")
            check(LogSourceDetector.detect("{\n  \"error\": \"AccessDenied\"\n}").kind == .jsonError,
                  "a JSON body should detect as a JSON/API error")
            check(LogSourceDetector.detect("openssl s_client -connect example.com:443\nVerify return code: 10").kind == .tls,
                  "openssl s_client output should detect as TLS")
            check(LogSourceDetector.detect("systemctl status nginx\n   Loaded: loaded\n   Active: failed").kind == .systemd,
                  "systemctl output should detect as a Linux service")
            check(LogSourceDetector.detect("hello world").kind == .genericText,
                  "unremarkable text should fall back to generic rather than guessing")

            // Spec §3's override must win over detection but still compute a
            // real severity from the content.
            let overridden = LogSourceDetector.detect(kubernetesLog, override: .nginx)
            check(overridden.kind == .nginx, "an explicit override should win over auto detection")
            check(overridden.severity >= .high, "an override should not freeze the severity read")

            check(LogSourceDetector.detect(kubernetesLog).severity >= .high,
                  "output containing ERROR lines should read as high severity or worse")
            check(LogSourceDetector.detect("2026-08-22 all good here").severity == .normal,
                  "benign output should read as normal severity")
        }

        // MARK: 3. Severity + grouping (spec §5, §6, §7)

        do {
            check(LogErrorExtractor.severity(forLine: "FATAL: kernel panic") == .critical, "fatal should classify critical")
            check(LogErrorExtractor.severity(forLine: "ERROR connection timeout") == .high, "error should classify high")
            check(LogErrorExtractor.severity(forLine: "WARN retrying in 5s") == .warning, "warn should classify warning")
            check(LogErrorExtractor.severity(forLine: "INFO started") == .informational, "info should classify informational")
            check(LogErrorExtractor.severity(forLine: "just a line") == .normal, "plain text should classify normal")

            // Spec §7's central promise: 43 near-identical lines are ONE row.
            var repeated = ""
            for i in 0..<43 {
                let second = String(format: "%02d", 11 + (i % 40))
                repeated += "2026-08-22T20:14:\(second)Z ERROR Readiness probe failed: connection refused on 10.244.3.\(17 + i):8081\n"
            }
            let groups = LogErrorExtractor.groups(in: repeated)
            check(groups.count == 1, "43 lines differing only in IP and timestamp should collapse to 1 pattern (got \(groups.count))")
            check(groups.first?.occurrences == 43, "the collapsed pattern should report all 43 occurrences")
            check((groups.first?.sampleLines.count ?? 99) <= LogErrorExtractor.maxSamplesPerGroup,
                  "sample lines should be capped rather than retaining every match")
            check(groups.first?.timeRange != nil, "a timestamped pattern should carry a time range")
            check(groups.first?.label.contains("<n>") == false,
                  "a group's label should be a real line, not the normalized pattern with placeholders")

            let mixed = LogErrorExtractor.groups(in: kubernetesLog)
            check(mixed.count >= 3, "distinct error shapes should stay distinct groups (got \(mixed.count))")
            check(mixed.first?.severity ?? .normal >= .high, "groups should sort highest severity first")
            check(!mixed.contains { $0.label.contains("service became healthy") },
                  "informational lines should not be extracted as error patterns")

            // Spec §6's condensed prompt body: a huge log must not be sent
            // whole, and the counted patterns must ride along instead.
            let huge = (0..<3000).map { "2026-08-22T20:14:11Z ERROR connection timeout to db-\($0)" }.joined(separator: "\n")
            let hugeGroups = LogErrorExtractor.groups(in: huge)
            let condensed = LogErrorExtractor.condensedForPrompt(huge, groups: hugeGroups)
            check(condensed.count < huge.count / 4, "a 3000-line log should be condensed, not sent whole")
            check(condensed.contains("COUNTED PATTERNS"), "the condensed body should carry the exact counted patterns")
            check(condensed.contains("lines omitted"), "the condensed body should say plainly that it omitted lines")

            check(LogErrorExtractor.findings(from: mixed).allSatisfy { $0.severity >= .high },
                  "only high-or-worse groups should be promoted into findings")
        }

        // MARK: 4. Timeline (spec §8)

        do {
            let groups = LogErrorExtractor.groups(in: kubernetesLog)
            let timeline = LogTimelineBuilder.build(text: kubernetesLog, groups: groups)
            check(timeline.isAvailable, "a timestamped log should produce a timeline")
            let events = timeline.events
            check(events.count >= 3, "the timeline should carry several beats (got \(events.count))")
            let stamps = events.map(\.timestamp)
            check(stamps == stamps.sorted(), "timeline events must be in chronological order")
            check(events.allSatisfy { kubernetesLog.contains($0.timestamp) },
                  "spec §8: every timeline timestamp must genuinely appear in the input")

            // Spec §8's explicit unavailable state - and it must say so in
            // the exact terms the spec asks for, not silently render empty.
            let noTimestamps = LogTimelineBuilder.build(
                text: "ERROR connection refused\nERROR connection refused",
                groups: LogErrorExtractor.groups(in: "ERROR connection refused\nERROR connection refused"))
            check(!noTimestamps.isAvailable, "a log with no timestamps must not produce a timeline")
            if case .unavailable(let reason) = noTimestamps {
                check(reason.lowercased().contains("timestamp"),
                      "the unavailable reason should name timestamps as the missing thing")
            } else {
                check(false, "expected the unavailable case for timestamp-free input")
            }
        }

        // MARK: 5. Correlation (spec §9)

        do {
            let groups = LogErrorExtractor.groups(in: kubernetesLog)
            let timeline = LogTimelineBuilder.build(text: kubernetesLog, groups: groups)
            let observed = LogCorrelationBuilder.observed(groups: groups, timeline: timeline)
            check(!observed.isEmpty, "counted patterns should produce observed correlation links")
            check(observed.allSatisfy { $0.kind == .observed },
                  "the local builder must only ever emit observed links")
            check(observed.allSatisfy { $0.evidence?.isEmpty == false },
                  "every observed link must name the counted evidence behind it")
            check(observed.map(\.order) == Array(0..<observed.count),
                  "observed link order should be a dense 0-based sequence")

            // The enforcement that makes the distinction meaningful: the AI
            // layer may never claim `.observed`.
            let json: [String: Any] = [
                "summary": "s",
                "correlation": [
                    ["kind": "observed", "text": "the model claims it observed this"],
                    ["kind": "inferred", "text": "a real inference"],
                    ["kind": "unknown", "text": "genuinely unknown"],
                ],
            ]
            let parsed = LogAnalyzerAI.parse(json)
            check(parsed != nil, "a reply with a summary and correlation should parse")
            check(parsed?.correlation.contains { $0.kind == .observed } == false,
                  "spec §9: an AI-claimed 'observed' link must be downgraded, not trusted")
            check(parsed?.correlation.filter { $0.kind == .inferred }.count == 2,
                  "the downgraded link should become inferred alongside the genuine one")
            check(parsed?.correlation.contains { $0.kind == .unknown } == true,
                  "an unknown link should survive as unknown")
        }

        // MARK: 6. AI reply parsing (spec §4, §10)

        do {
            let full = """
            {"summary": "Probe port mismatch.",
             "findings": [{"severity": "critical", "title": "Probe fails", "detail": "Nothing listens on 8081."}],
             "rootCause": {"summary": "Readiness probe port mismatch", "explanation": "e",
                           "confidence": "high", "evidence": ["a"], "missingEvidence": ["b"],
                           "contradictingEvidence": []},
             "nextSteps": ["Fix the probe port"],
             "suggestedCommands": [{"title": "Check probe", "command": "kubectl describe pod x -n y", "rationale": "r"}],
             "correlation": [{"kind": "inferred", "text": "c"}],
             "neededEvidence": ["the deployment manifest"]}
            """
            guard let object = LogAnalyzerAI.decodeJSONObject(from: full), let ai = LogAnalyzerAI.parse(object) else {
                check(false, "a well-formed reply should parse")
                return finish(failures)
            }
            check(ai.findings.first?.severity == .critical, "finding severity should round-trip")
            check(ai.rootCause?.confidence == .high, "confidence should round-trip")
            check(ai.rootCause?.missingEvidence == ["b"], "missing evidence should round-trip")
            check(ai.nextSteps == ["Fix the probe port"], "next steps should round-trip")
            check(ai.suggestedCommands.first?.command == "kubectl describe pod x -n y", "commands should round-trip")
            check(ai.neededEvidence == ["the deployment manifest"], "needed evidence should round-trip")

            // A model wrapping its JSON in a fence, or adding a sentence, is
            // the common real-world deviation - both must still parse.
            let fenced = "```json\n{\"summary\": \"s\", \"findings\": []}\n```"
            check(LogAnalyzerAI.decodeJSONObject(from: fenced)?["summary"] as? String == "s",
                  "a fenced JSON reply should still decode")
            let chatty = "Here you go:\n{\"summary\": \"s2\", \"findings\": []}\nHope that helps."
            check(LogAnalyzerAI.decodeJSONObject(from: chatty)?["summary"] as? String == "s2",
                  "a reply with prose around the JSON should still decode")
            check(LogAnalyzerAI.decodeJSONObject(from: "not json at all") == nil,
                  "genuinely unparseable output should decode to nil rather than something invented")

            // An empty reply must be a failure, not a blank analysis card.
            check(LogAnalyzerAI.parse(["findings": [], "nextSteps": []]) == nil,
                  "a reply with nothing usable should be treated as a failure")

            // The envelope parser, against `claude -p --output-format json`'s
            // real shape (including its error flag).
            let envelope = "{\"result\":\"hello\",\"is_error\":false,\"session_id\":\"x\"}"
            if case .success(let text) = LogAnalyzerAI.parseEnvelope(
                outData: Data(envelope.utf8), errData: Data(), status: 0) {
                check(text == "hello", "the envelope's result text should be extracted verbatim")
            } else {
                check(false, "a well-formed claude envelope should parse")
            }
            let errored = "{\"result\":\"boom\",\"is_error\":true}"
            if case .failure = LogAnalyzerAI.parseEnvelope(outData: Data(errored.utf8), errData: Data(), status: 0) {
                // expected
            } else {
                check(false, "an is_error envelope should be a failure")
            }
        }

        // MARK: 7. The AI prompt never carries a secret (spec §14, byte-level)

        do {
            // Exactly what the page does: redact on the way in, then build
            // the prompt from the redacted text only.
            let redacted = LogRedactor.redact(secretyLog)
            let local = LogAnalyzerController.buildLocalAnalysis(text: redacted.text, override: nil)
            let prompt = LogAnalyzerAI.prompt(mode: .analyze, detection: local.detection,
                                              groups: local.groups, timeline: local.timeline,
                                              body: redacted.text)
            for secret in secretsPlanted {
                check(!prompt.contains(secret),
                      "the built AI prompt must not contain the planted secret \(secret.prefix(6))…")
            }
            check(prompt.contains(LogRedactor.placeholder), "the prompt should carry the redaction placeholders")
            check(prompt.contains("Do not label anything \"observed\""),
                  "the prompt must carry spec §9's observed-is-forbidden instruction")
            check(prompt.contains("exact"), "the prompt must tell the model the local counts are exact")

            let investigate = LogAnalyzerAI.investigatePrompt(detection: local.detection, rootCause: nil,
                                                              body: redacted.text)
            for secret in secretsPlanted {
                check(!investigate.contains(secret), "the investigate-further prompt must not contain a secret either")
            }
        }

        // MARK: 8. Command matching (spec §11)

        do {
            let saved = [
                DevOpsCommand(id: "kubernetes/describe-pod", name: "Describe a pod",
                              description: "Full pod state and events", category: "kubernetes",
                              commandTemplate: "kubectl describe pod {{pod}} -n {{namespace}}",
                              parameters: [], tags: [], risk: .readOnly),
                DevOpsCommand(id: "kubernetes/get-events", name: "Recent events",
                              description: "Namespace events, newest last", category: "kubernetes",
                              commandTemplate: "kubectl get events -n {{namespace}} --sort-by=.lastTimestamp",
                              parameters: [], tags: [], risk: .readOnly),
                DevOpsCommand(id: "linux/journal", name: "Service journal", description: "Recent unit logs",
                              category: "linux", commandTemplate: "journalctl -u {{unit}} -n 200",
                              parameters: [], tags: [], risk: .readOnly),
            ]

            let match = LogAnalyzerCommandMatcher.bestMatch(
                for: "kubectl describe pod search-api-7d8f -n search-api", in: saved)
            check(match?.id == "kubernetes/describe-pod",
                  "a concrete command should match the equivalent saved template")

            check(LogAnalyzerCommandMatcher.bestMatch(for: "kubectl delete pod x -n y", in: saved) == nil,
                  "a different subcommand must not match (delete is not describe)")
            check(LogAnalyzerCommandMatcher.bestMatch(for: "aws logs tail /aws/lambda/x", in: saved) == nil,
                  "a different executable must not match")

            // Spec §11's actual behaviour: the saved template replaces the
            // generated text, and the row is labelled as coming from the
            // library.
            let suggestions = [
                LogSuggestedCommand(order: 0, title: "Check the pod", command: "kubectl describe pod abc -n def",
                                    rationale: "", libraryCommandID: nil, libraryCommandName: nil),
                LogSuggestedCommand(order: 1, title: "Tail lambda logs", command: "aws logs tail /aws/lambda/x",
                                    rationale: "", libraryCommandID: nil, libraryCommandName: nil),
            ]
            let resolved = LogAnalyzerCommandMatcher.resolve(suggestions, against: saved)
            check(resolved[0].libraryCommandID == "kubernetes/describe-pod",
                  "a matched suggestion should be re-pointed at the saved command")
            check(resolved[0].command == "kubectl describe pod {{pod}} -n {{namespace}}",
                  "a matched suggestion should adopt the saved command's own template")
            check(resolved[1].libraryCommandID == nil,
                  "an unmatched suggestion should stay exactly as generated")
            check(resolved[1].command == "aws logs tail /aws/lambda/x",
                  "an unmatched suggestion's text must not be rewritten")

            let fallback = LogAnalyzerCommandMatcher.libraryFallback(for: .kubernetes, in: saved)
            check(fallback.count == 2, "the fallback should offer this source's own saved read-only commands")
            check(fallback.allSatisfy { $0.isFromLibrary }, "every fallback command comes from the library by definition")
        }

        // MARK: 9. Storage (spec §15, §23, §25) - including the byte-level secret check

        do {
            let dir = scratch.appendingPathComponent("store", isDirectory: true)
            setenv("FM_LOG_ANALYZER_DIR", dir.path, 1)
            defer { unsetenv("FM_LOG_ANALYZER_DIR") }

            let store = LogAnalyzerStore()
            check(store.gitSync == nil, "an FM_LOG_ANALYZER_DIR override must bypass git sync entirely")
            check(store.history().isEmpty, "a fresh store should have no history")

            let redacted = LogRedactor.redact(secretyLog)
            let local = LogAnalyzerController.buildLocalAnalysis(text: redacted.text, override: nil)
            var investigation = LogInvestigation(title: "Search API probe failure")
            investigation.evidence = [LogEvidenceItem(label: "kubectl describe", origin: .terminal,
                                                      sourceDetail: "EKS Preprod Bastion",
                                                      text: redacted.text, detection: local.detection,
                                                      redactionCount: redacted.count)]
            investigation.analysis = LogAnalysis(local: local, ai: nil, aiFailure: nil,
                                                 mode: .analyze, analyzedAt: Date())

            // Default: nothing on disk at all.
            investigation.storage = .doNotSave
            check(store.save(investigation) == nil, "the default storage choice must write nothing")
            check(store.history().isEmpty, "a do-not-save investigation must not appear in history")

            // Metadata only: yaml, and definitely no log content.
            investigation.storage = .metadataOnly
            guard let metadataDir = store.save(investigation) else {
                check(false, "metadata-only should write an investigation directory")
                return finish(failures)
            }
            check(fm.fileExists(atPath: metadataDir.appendingPathComponent("investigation.yaml").path),
                  "metadata-only should write investigation.yaml")
            check(!fm.fileExists(atPath: metadataDir.appendingPathComponent("analysis.md").path),
                  "metadata-only must not write analysis.md")
            check(!fm.fileExists(atPath: metadataDir.appendingPathComponent("evidence").path),
                  "metadata-only must not write any evidence file")
            let metadataText = (try? String(contentsOf: metadataDir.appendingPathComponent("investigation.yaml"), encoding: .utf8)) ?? ""
            check(!metadataText.contains("connection refused"),
                  "metadata-only must not carry raw log lines")
            check(metadataText.contains("Search API probe failure"), "metadata should carry the title")
            check(store.history().count == 1, "a saved investigation should appear in history")

            // Complete: analysis.md + evidence, still with no secrets.
            investigation.storage = .complete
            guard let completeDir = store.save(investigation) else {
                check(false, "complete storage should write an investigation directory")
                return finish(failures)
            }
            check(fm.fileExists(atPath: completeDir.appendingPathComponent("analysis.md").path),
                  "complete storage should write analysis.md")
            let evidenceDir = completeDir.appendingPathComponent("evidence", isDirectory: true)
            let evidenceFiles = (try? fm.contentsOfDirectory(atPath: evidenceDir.path)) ?? []
            check(evidenceFiles.count == 1, "complete storage should write one file per evidence item")
            check(store.history().count == 1, "re-saving must replace, not duplicate, the stored investigation")

            // The byte-level check: walk every file that was written and
            // grep it for the planted secrets.
            var scannedFiles = 0
            if let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) {
                for case let url as URL in walker {
                    guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                    scannedFiles += 1
                    for secret in secretsPlanted {
                        check(!text.contains(secret),
                              "saved file \(url.lastPathComponent) must not contain a secret")
                    }
                }
            }
            check(scannedFiles >= 2, "the secret scan should actually have read files (read \(scannedFiles))")

            // Reload round trip.
            guard let reloaded = store.load(id: investigation.id) else {
                check(false, "a complete investigation should reload")
                return finish(failures)
            }
            check(reloaded.title == investigation.title, "the reloaded title should match")
            check(reloaded.evidence.count == 1, "the reloaded evidence shell should match")
            check(reloaded.evidence.first?.text.contains("connection refused") == true,
                  "a complete save should reload its evidence text")
            check(reloaded.evidence.first?.origin == .terminal, "the evidence origin should round-trip")

            // Downgrading to do-not-save must genuinely remove the content,
            // not leave orphaned files behind.
            investigation.storage = .doNotSave
            _ = store.save(investigation)
            check(store.history().isEmpty, "downgrading to do-not-save must remove the saved investigation")
            check(!fm.fileExists(atPath: completeDir.path), "the investigation directory should be gone")
        }

        // MARK: 10. Artifacts (spec §16-§19)

        do {
            let local = LogAnalyzerController.buildLocalAnalysis(text: kubernetesLog, override: nil)
            var investigation = LogInvestigation(title: "Search API probe failure")
            investigation.evidence = [LogEvidenceItem(label: "kubectl describe", origin: .terminal,
                                                      sourceDetail: "EKS Preprod Bastion",
                                                      text: kubernetesLog, detection: local.detection,
                                                      redactionCount: 0)]
            let ai = LogAIAnalysis(
                findings: [LogFinding(severity: .critical, title: "Probe fails", detail: "Nothing listens on 8081.", meta: nil)],
                rootCause: LogRootCause(summary: "Readiness probe port mismatch", explanation: "Probe 8081, app 8080.",
                                        confidence: .high, evidence: ["Port: 8080/TCP"],
                                        missingEvidence: ["The Deployment manifest"], contradictingEvidence: []),
                nextSteps: ["Update readinessProbe.port to 8080"],
                suggestedCommands: [LogSuggestedCommand(order: 0, title: "Check the probe port",
                                                        command: "kubectl describe pod search-api -n search-api",
                                                        rationale: "Shows the configured probe",
                                                        libraryCommandID: nil, libraryCommandName: nil)],
                correlation: [LogCorrelationLink(order: 0, kind: .inferred, text: "Probe fails → pod never Ready", evidence: nil)],
                neededEvidence: ["The Deployment manifest"],
                summary: "The readiness probe targets a port nothing listens on.")
            investigation.analysis = LogAnalysis(local: local, ai: ai, aiFailure: nil, mode: .analyze, analyzedAt: Date())

            let incident = LogAnalyzerArtifacts.incidentMarkdown(investigation)
            for section in ["## Impact", "## Start time", "## Timeline", "## Symptoms",
                            "## Evidence", "## Root cause", "## Resolution", "## Next steps"] {
                check(incident.contains(section), "spec §17: the incident must contain \(section)")
            }
            check(incident.contains("EKS Preprod Bastion"),
                  "spec §17: the incident must retain a reference to the evidence's own source")

            let runbook = LogAnalyzerArtifacts.runbookMarkdown(investigation)
            for section in ["## Symptoms", "## Investigation", "## Resolution", "## Prevention"] {
                check(runbook.contains(section), "spec §18: the runbook must contain \(section)")
            }
            // The integration that makes a generated runbook actually
            // runnable: SRE Lead's `run_runbook` reads a runbook's fenced
            // command lines, and `DocsRunbookMetadata.commandLines` is the
            // Swift mirror of that same extraction.
            let commandLines = DocsRunbookMetadata.commandLines(in: runbook)
            check(commandLines.contains("kubectl describe pod search-api -n search-api"),
                  "spec §18: a generated runbook's commands must be extractable by the runbook runner's own parser")

            let ticket = LogAnalyzerArtifacts.ticketMarkdown(investigation)
            for section in ["## Summary", "## Description", "## Impact", "## Root cause",
                            "## Evidence", "## Timeline", "## Resolution", "## Preventive actions"] {
                check(ticket.contains(section), "spec §19: the ticket must contain \(section)")
            }
            check(ticket.lowercased().contains("nothing was filed"),
                  "spec §19: the ticket draft must say plainly that nothing was filed automatically")

            let full = LogAnalyzerArtifacts.fullAnalysisText(investigation)
            check(full.contains("Readiness probe port mismatch"), "the full copy should carry the root cause")
            check(full.contains("Missing evidence"), "the full copy should carry what could not be established")
            check(LogAnalyzerArtifacts.rootCauseText(investigation).contains("Confidence: High"),
                  "the root-cause copy should state its confidence")

            // A never-analyzed investigation must produce honest text, not a
            // crash or an empty section that reads as "nothing was wrong".
            let empty = LogInvestigation(title: "Nothing yet")
            check(LogAnalyzerArtifacts.fullAnalysisText(empty).contains("not been analyzed"),
                  "an unanalyzed investigation should say so")
            check(!LogAnalyzerArtifacts.incidentMarkdown(empty).isEmpty,
                  "incident rendering should not crash on an unanalyzed investigation")
        }

        // MARK: 11. Compare / diff (spec §20, §21)

        do {
            let before = """
            2026-08-22T20:10:00Z INFO  http server listening on :8080
            2026-08-22T20:10:05Z INFO  request served 200
            """
            let after = """
            2026-08-22T20:20:00Z INFO  http server listening on :8080
            2026-08-22T20:20:05Z ERROR HTTP 503 Service Unavailable at ingress
            2026-08-22T20:20:06Z ERROR HTTP 503 Service Unavailable at ingress
            """
            let result = LogAnalyzerArtifacts.compare(before: before, after: after)
            check(result.newPatterns.contains { $0.label.contains("503") },
                  "a comparison should report an error that only appears after")
            check(result.resolvedPatterns.isEmpty, "nothing errored before, so nothing should be reported resolved")
            check(!result.rows.isEmpty, "the comparison should carry the DiffEngine rows for rendering")
            check(result.rows.contains { $0.kind != .unchanged }, "the diff should register changed lines")

            // The reverse direction must report the same pattern as resolved.
            let reversed = LogAnalyzerArtifacts.compare(before: after, after: before)
            check(reversed.resolvedPatterns.contains { $0.label.contains("503") },
                  "reversing before/after should report the pattern as resolved")

            // A pattern that got worse rather than appearing.
            let worseBefore = "ERROR connection timeout to db\n"
            let worseAfter = String(repeating: "ERROR connection timeout to db\n", count: 5)
            let worse = LogAnalyzerArtifacts.compare(before: worseBefore, after: worseAfter)
            check(worse.worsenedPatterns.first?.before == 1 && worse.worsenedPatterns.first?.after == 5,
                  "a pattern occurring more often after should be reported as worse, with both counts")

            let text = LogAnalyzerArtifacts.comparisonText(result, beforeLabel: "Before", afterLabel: "After")
            check(text.contains("New errors"), "the comparison copy should list new errors")
            check(text.contains("Resolved errors"), "the comparison copy should list resolved errors")
        }

        // MARK: 12. Terminal capture scope (spec §2 - the captain's own rule)

        do {
            let bufferLines = (0..<1200).map { "buffer line \($0)" }
            let finished = TerminalBlock(id: UUID(), commandText: "kubectl describe pod x",
                                         outputText: "Port: 8080/TCP\nReadiness: http-get http://:8081/healthz",
                                         status: .finished(exitCode: 0))
            let running = TerminalBlock(id: UUID(), commandText: "kubectl logs -f x",
                                        outputText: "", status: .running)

            // 1. A manual selection always wins.
            let selected = LogTerminalCaptureBuilder.build(selection: "just these two lines\nof output",
                                                           blocks: [finished], bufferLines: bufferLines,
                                                           hasBlockTracking: true)
            check(selected.scope == .selection, "a manual selection must override the block capture")
            check(selected.text == "just these two lines\nof output", "the selection should be sent verbatim")

            // 2. Otherwise, the last COMPLETED block - never the whole
            //    scrollback, never the viewport.
            let blockCapture = LogTerminalCaptureBuilder.build(selection: nil, blocks: [finished, running],
                                                               bufferLines: bufferLines, hasBlockTracking: true)
            if case .lastCommandBlock(let command) = blockCapture.scope {
                check(command == "kubectl describe pod x", "the capture should name the command it captured")
            } else {
                check(false, "with a completed block present, that block should be captured")
            }
            check(blockCapture.text.contains("Port: 8080/TCP"), "the block's output should be captured")
            check(blockCapture.text.contains("kubectl describe pod x"), "the block's command line should be captured")
            check(!blockCapture.text.contains("buffer line 0"), "the whole scrollback must not be captured")
            check(blockCapture.fallbackNotice == nil, "an exact capture needs no fallback notice")

            // A still-running block is skipped - its output is incomplete by
            // definition, and Stage 0 never populates it anyway.
            let onlyRunning = LogTerminalCaptureBuilder.build(selection: nil, blocks: [running],
                                                              bufferLines: bufferLines, hasBlockTracking: true)
            if case .recentOutputFallback = onlyRunning.scope {
                check(onlyRunning.fallbackNotice?.contains("No completed command") == true,
                      "with only a running block, the notice should say no command has completed yet")
            } else {
                check(false, "a still-running block must not be captured as if it were complete")
            }

            // 3. No block tracking at all (a host that never opted in) - a
            //    bounded tail, honestly labelled, and NOT the full scrollback.
            let fallback = LogTerminalCaptureBuilder.build(selection: nil, blocks: [],
                                                           bufferLines: bufferLines, hasBlockTracking: false)
            if case .recentOutputFallback(let lines) = fallback.scope {
                check(lines == LogTerminalCaptureBuilder.fallbackTailLines,
                      "the fallback should capture exactly its bounded tail (got \(lines))")
            } else {
                check(false, "with no blocks and no tracking, the fallback should be used")
            }
            check(!fallback.text.contains("buffer line 0"), "the fallback must not capture the whole scrollback")
            check(fallback.text.contains("buffer line 1199"), "the fallback should capture the most recent lines")
            check(fallback.fallbackNotice?.contains("Block View") == true,
                  "the fallback notice should name the per-host opt-in that enables exact capture")

            // Trailing blank rows (a terminal pre-fills its viewport) must
            // not be counted as captured output.
            let padded = ["real output", "", "", "", ""]
            let trimmed = LogTerminalCaptureBuilder.build(selection: nil, blocks: [], bufferLines: padded,
                                                          hasBlockTracking: false)
            check(trimmed.text == "real output", "trailing blank buffer rows should be trimmed")

            // Whitespace-only selection is not a selection.
            let blankSelection = LogTerminalCaptureBuilder.build(selection: "   \n  ", blocks: [finished],
                                                                 bufferLines: bufferLines, hasBlockTracking: true)
            check(blankSelection.scope != .selection, "a whitespace-only selection should not override the block")
        }

        // MARK: 12b. Title derivation + analysis-mode coverage

        do {
            let title = LogAnalyzerController.derivedTitle(from: kubernetesLog, fallback: "fallback")
            check(title.contains("Readiness probe failed"),
                  "a derived title should name the first genuinely error-ish line, not the first line")
            check(LogAnalyzerController.derivedTitle(from: "all quiet here", fallback: "fallback") == "all quiet here",
                  "with no error line, the first real line should be the title")
            check(LogAnalyzerController.derivedTitle(from: "   \n  \n", fallback: "fallback") == "fallback",
                  "empty input should fall back to the supplied label")

            // Spec §22: all ten modes exist, each with its own instruction,
            // and every one of them produces a prompt carrying the shared
            // schema (one parser handles all ten - see `LogAnalyzerAI`).
            check(LogAnalysisMode.allCases.count == 10, "spec §22 lists ten analysis modes")
            let instructions = Set(LogAnalysisMode.allCases.map(\.instruction))
            check(instructions.count == 10, "each mode should carry its own distinct instruction")
            let local = LogAnalyzerController.buildLocalAnalysis(text: kubernetesLog, override: nil)
            for analysisMode in LogAnalysisMode.allCases {
                let prompt = LogAnalyzerAI.prompt(mode: analysisMode, detection: local.detection,
                                                  groups: local.groups, timeline: local.timeline,
                                                  body: kubernetesLog)
                check(prompt.contains(analysisMode.instruction), "\(analysisMode.rawValue)'s own instruction should reach the prompt")
                check(prompt.contains("\"suggestedCommands\""), "every mode should ask for the same response schema")
            }
        }

        // MARK: 13. End-to-end against a fake `claude` (the real Process path)

        do {
            let reply: [String: Any] = [
                "summary": "Readiness probe port mismatch.",
                "findings": [["severity": "critical", "title": "Probe fails", "detail": "Nothing listens on 8081."]],
                "rootCause": ["summary": "Probe port mismatch", "explanation": "e", "confidence": "high",
                              "evidence": ["Port: 8080/TCP"], "missingEvidence": [], "contradictingEvidence": []],
                "nextSteps": ["Fix the probe"],
                "suggestedCommands": [["title": "Describe the pod",
                                       "command": "kubectl describe pod search-api -n search-api",
                                       "rationale": "shows the probe"]],
                "correlation": [["kind": "inferred", "text": "probe fails -> not Ready"]],
                "neededEvidence": ["the Deployment manifest"],
            ]
            guard let innerData = try? JSONSerialization.data(withJSONObject: reply),
                  let inner = String(data: innerData, encoding: .utf8),
                  let envelopeData = try? JSONSerialization.data(
                    withJSONObject: ["result": inner, "is_error": false, "session_id": "test"]),
                  let envelope = String(data: envelopeData, encoding: .utf8) else {
                check(false, "could not build the fake claude reply")
                return finish(failures)
            }

            let scriptURL = scratch.appendingPathComponent("fake-claude")
            // Single-quote the JSON body; it contains double quotes but no
            // single quotes (JSON escapes those as-is only inside strings,
            // and none of the values above use one).
            let script = "#!/bin/sh\ncat <<'FAKEEOF'\n\(envelope)\nFAKEEOF\n"
            try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            LogAnalyzerAI.claudePathOverrideForTests = scriptURL.path
            defer { LogAnalyzerAI.claudePathOverrideForTests = nil }
            check(LogAnalyzerAI.isAvailable, "the fake claude should register as available")

            let local = LogAnalyzerController.buildLocalAnalysis(text: kubernetesLog, override: nil)
            let semaphore = DispatchSemaphore(value: 0)
            var received: LogAIAnalysis?
            var failure: String?
            // `LogAnalyzerAI` completes on the main queue, so this cannot
            // block the main thread waiting for it - run the wait on a
            // background thread and pump the main run loop here instead.
            DispatchQueue.global().async {
                LogAnalyzerAI.analyze(mode: .analyze, local: local, body: kubernetesLog) { result in
                    switch result {
                    case .success(let ai): received = ai
                    case .failure(let error): failure = error.message
                    }
                    semaphore.signal()
                }
            }
            let deadline = Date().addingTimeInterval(30)
            while semaphore.wait(timeout: .now()) == .timedOut, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            check(failure == nil, "the fake claude round trip should not fail (\(failure ?? ""))")
            check(received?.rootCause?.summary == "Probe port mismatch",
                  "the real Process + parse path should return the fake reply's root cause")
            check(received?.suggestedCommands.first?.command == "kubectl describe pod search-api -n search-api",
                  "the real path should return the fake reply's suggested command")
        }

        return finish(failures)
    }

    private static func finish(_ failures: [String]) -> Bool {
        if !failures.isEmpty {
            for f in failures { FileHandle.standardError.write(Data(("FAIL: " + f + "\n").utf8)) }
            FileHandle.standardError.write(Data("\(failures.count) failure(s)\n".utf8))
        } else {
            FileHandle.standardOutput.write(Data("LogAnalyzerSelfTest: all checks passed\n".utf8))
        }
        return failures.isEmpty
    }
}
