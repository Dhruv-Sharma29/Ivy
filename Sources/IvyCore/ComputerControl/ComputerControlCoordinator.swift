import Foundation
import CoreGraphics

/// Result of running the sequential computer control loop.
public enum ComputerControlRunResult: Equatable, Sendable {
    case succeeded(summary: String)
    case paused(TaskPause)
    case failed(reason: String)
    case cancelled
}

/// Coordinates the sequential observe-decide-execute adaptive computer control loop.
///
/// Ensures:
/// 1. Exactly one action per decision.
/// 2. Invalid or unknown model outputs cannot execute.
/// 3. Fresh observed state follows each executed action.
/// 4. Budgets and all primitive calls are strictly tracked through the dispatcher.
@MainActor
public final class ComputerControlCoordinator: ObservableObject {
    public let session: ComputerControlSession
    public let decisionProvider: ComputerDecisionProviding
    public let dispatcher: ToolDispatcher
    public let observationProvider: any DesktopObservationProviding
    public weak var feedbackController: (any ComputerControlFeedbackManaging)?

    public private(set) var isCancelled: Bool = false
    public private(set) var history: [ComputerActionHistoryItem] = []
    public private(set) var lastObservation: DesktopObservation?

    public init(
        session: ComputerControlSession,
        decisionProvider: ComputerDecisionProviding,
        dispatcher: ToolDispatcher,
        observationProvider: any DesktopObservationProviding,
        feedbackController: (any ComputerControlFeedbackManaging)? = nil
    ) {
        self.session = session
        self.decisionProvider = decisionProvider
        self.dispatcher = dispatcher
        self.observationProvider = observationProvider
        self.feedbackController = feedbackController
    }

    /// Stops the active loop and invalidates session tokens.
    public func cancel() {
        isCancelled = true
        session.stop(reason: "Execution stopped by user")
        feedbackController?.clearTarget()
        feedbackController?.stop()
    }

    /// Pauses the active loop without losing completed history.
    public func pause(reason: ComputerControlPauseReason = .userRequested) {
        session.pause(reason: reason)
        feedbackController?.pause(reason: reason)
    }

    /// Resumes the session.
    public func resume() -> Bool {
        let res = session.resume()
        if case .success = res {
            feedbackController?.resume()
            return true
        }
        return false
    }

    /// Runs the sequential observe -> decide -> execute loop for the given goal and scope.
    public func runLoop(
        runID: UUID,
        goal: String,
        scope: ComputerControlScope,
        budget: TaskBudget,
        startTime: Date = Date(),
        existingStepCount: Int = 0,
        existingToolCalls: Int = 0,
        onStepCreated: (TaskStep) -> Void,
        onStepUpdated: (TaskStep) -> Void,
        onToolCallDispatched: () -> Void,
        isTaskCancelled: () -> Bool
    ) async -> ComputerControlRunResult {
        guard !isCancelled && !isTaskCancelled() && session.state.isActive else {
            return .cancelled
        }
        var stepCount = existingStepCount
        var totalToolCalls = existingToolCalls

        // Available primitive tools for the model
        let availableTools = dispatcher.registry.allTools
            .filter { ComputerDecisionValidator.allowedTools.contains($0.name) }
            .map(\.declaration)

        feedbackController?.updateStatus("Starting desktop session for \(scope.bundleIdentifier)...")

        while !isCancelled && !isTaskCancelled() && session.state.isActive {
            // Check budget constraints
            if stepCount >= budget.maxSteps {
                session.pause(reason: .budgetExhausted)
                feedbackController?.pause(reason: .budgetExhausted)
                return .paused(.budget("Action step limit of \(budget.maxSteps) steps reached."))
            }

            if totalToolCalls >= budget.maxToolCalls {
                session.pause(reason: .budgetExhausted)
                feedbackController?.pause(reason: .budgetExhausted)
                return .paused(.budget("Dispatched tool call limit of \(budget.maxToolCalls) calls reached."))
            }

            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed >= budget.maxDuration {
                session.pause(reason: .budgetExhausted)
                feedbackController?.pause(reason: .budgetExhausted)
                return .paused(.budget("Task duration limit of \(Int(budget.maxDuration / 60)) minutes reached."))
            }

            // 1. Observe state: dispatch ui_observe through dispatcher so it counts against budget & safety
            feedbackController?.updateStatus("Observing \(scope.bundleIdentifier)...")
            let obsCall = FunctionCall(
                name: "ui_observe",
                args: ["bundle_id": AnyCodable(scope.bundleIdentifier)],
                id: "obs-\(runID.uuidString.prefix(6))-\(stepCount)"
            )
            onToolCallDispatched()
            totalToolCalls += 1
            let obsResponse = await dispatcher.dispatch(obsCall)

            guard !isCancelled && !isTaskCancelled() && session.state.isActive else {
                return .cancelled
            }

            if obsResponse.isCancelled || obsResponse.isSafetyRejection {
                return .cancelled
            }

            // Capture actual structured observation
            let observation: DesktopObservation
            do {
                observation = try await observationProvider.observe(session: session, scope: scope)
                lastObservation = observation
            } catch {
                session.pause(reason: .staleTarget)
                feedbackController?.pause(reason: .staleTarget)
                return .paused(.stepFailed(stepID: "\(stepCount)", reason: "Observation failed: \(error.localizedDescription)"))
            }

            // 2. Decide next action: one action per decision
            feedbackController?.updateStatus("Deciding next action for \(scope.bundleIdentifier)... (Step \(stepCount + 1)/\(budget.maxSteps))")
            let decision: ComputerDecision
            do {
                decision = try await decisionProvider.decideNextAction(
                    goal: goal,
                    scope: scope,
                    observation: observation,
                    history: history,
                    availableTools: availableTools
                )
            } catch {
                // Invalid or unknown output cannot execute
                session.pause(reason: .userRequested)
                feedbackController?.pause(reason: .userRequested)
                return .paused(.stepFailed(stepID: "\(stepCount)", reason: "Model decision invalid or rejected: \(error.localizedDescription)"))
            }

            guard !isCancelled && !isTaskCancelled() && session.state.isActive else {
                return .cancelled
            }

            // 3. Process decision
            switch decision {
            case .finish(let summary):
                session.complete(summary: summary)
                feedbackController?.clearTarget()
                feedbackController?.updateStatus("Goal accomplished: \(summary)")
                return .succeeded(summary: summary)

            case .ask(let reason):
                session.pause(reason: .userRequested)
                feedbackController?.pause(reason: .userRequested)
                return .paused(.stepFailed(stepID: "\(stepCount)", reason: "Ivy needs input: \(reason)"))

            case .abort(let reason):
                session.stop(reason: reason)
                feedbackController?.stop()
                return .failed(reason: "Desktop task aborted: \(reason)")

            case .action(let call, let explanation):
                if totalToolCalls >= budget.maxToolCalls {
                    session.pause(reason: .budgetExhausted)
                    feedbackController?.pause(reason: .budgetExhausted)
                    return .paused(.budget("Dispatched tool call limit of \(budget.maxToolCalls) calls reached."))
                }
                stepCount += 1
                let stepID = "\(stepCount)"
                let targetDesc = call.args["element_id"]?.stringValue ?? (call.args["x"] != nil ? "(\(call.args["x"]?.doubleValue ?? 0), \(call.args["y"]?.doubleValue ?? 0))" : "")
                let title = explanation ?? "\(call.name) \(targetDesc)".trimmingCharacters(in: .whitespaces)

                // Highlight target element if present in current observation
                if let elementID = call.args["element_id"]?.stringValue,
                   let element = observation.elements.first(where: { $0.id == elementID }) {
                    feedbackController?.updateTarget(
                        element: element,
                        point: CGPoint(x: element.frame.midX, y: element.frame.midY)
                    )
                } else if let x = call.args["x"]?.doubleValue, let y = call.args["y"]?.doubleValue {
                    feedbackController?.updateTarget(element: nil, point: CGPoint(x: x, y: y))
                }

                feedbackController?.updateStatus("\(title)... (Step \(stepCount)/\(budget.maxSteps))")

                var taskStep = TaskStep(
                    id: stepID,
                    title: title,
                    tool: call.name,
                    arguments: call.args
                )
                taskStep.status = .running
                onStepCreated(taskStep)

                // Inject observation token into arguments
                var finalArgs = call.args
                if finalArgs["token"] == nil {
                    finalArgs["token"] = AnyCodable(observation.token.id.uuidString)
                }

                let actionCall = FunctionCall(
                    name: call.name,
                    args: finalArgs,
                    id: "act-\(runID.uuidString.prefix(6))-\(stepID)"
                )

                onToolCallDispatched()
                totalToolCalls += 1

                // Dispatch primitive through ToolDispatcher & SafetyGate
                let response = await dispatcher.dispatch(actionCall)

                guard !isCancelled && !isTaskCancelled() else {
                    taskStep.status = .cancelled
                    onStepUpdated(taskStep)
                    return .cancelled
                }

                let outputText = response.resultMessage ?? response.errorMessage ?? ""
                taskStep.output = TaskStep.clip(outputText)

                if response.isCancelled || response.isSafetyRejection {
                    taskStep.status = .failed("Action declined by user.")
                    onStepUpdated(taskStep)
                    session.pause(reason: .userRequested)
                    feedbackController?.pause(reason: .userRequested)
                    return .paused(.stepFailed(stepID: stepID, reason: "You declined this step."))
                }

                if response.isSuccess {
                    taskStep.status = .succeeded
                    onStepUpdated(taskStep)
                    history.append(ComputerActionHistoryItem(
                        stepNumber: stepCount,
                        toolName: call.name,
                        summary: title,
                        result: response.resultMessage ?? "OK",
                        succeeded: true
                    ))
                } else {
                    let errMsg = response.errorMessage ?? "Action failed"
                    taskStep.status = .failed(errMsg)
                    onStepUpdated(taskStep)
                    history.append(ComputerActionHistoryItem(
                        stepNumber: stepCount,
                        toolName: call.name,
                        summary: title,
                        result: errMsg,
                        succeeded: false
                    ))
                }
            }
        }

        if isCancelled || isTaskCancelled() || !session.state.isActive {
            return .cancelled
        }
        return .succeeded(summary: "Control loop ended.")
    }
}
