@testable import StockPlanBackend
import Testing

/// Guards the narrow predicate behind the forced-`tool_choice` retry.
///
/// The retry exists because a model can answer the *intent* of a data question
/// in prose and call nothing, which the turn loop would return verbatim as the
/// final answer — observed in production on 2026-08-27, where "How are my
/// expenses" was answered with "Let me check your latest expenses for you." and
/// nothing further.
///
/// The predicate has to stay narrow in the other direction too: a direct answer
/// with no tool call is legitimate, and forcing a tool on it would make the
/// model call something irrelevant.
@Suite("AI assistant tool nudge")
struct AIAssistantToolNudgeTests {
    @Test(
        "An announced-but-unperformed lookup is detected",
        arguments: [
            "Let me check your latest expenses for you.",
            "let me check both your expenses and your current budget status",
            "Let me look at your portfolio.",
            "I'll fetch your expenses for this month.",
            "I will pull your recent transactions.",
            "One moment while I get that.",
            "Sure — checking your spending now.",
        ]
    )
    func detectsAnnouncement(_ text: String) {
        #expect(AIAssistantTurnService.looksLikeUnfulfilledIntent(text))
    }

    @Test(
        "A real answer is left alone",
        arguments: [
            "Hey! 👋 Ready when you are — what can I help you with?",
            "US inflation was 3.1% year over year in July 2026.",
            "You spent €1,240 this month, up 8% on June.",
            "Your portfolio is up 2.3% today, led by NVDA.",
            "I can't help with that, but I can show your spending.",
        ]
    )
    func leavesRealAnswersAlone(_ text: String) {
        #expect(!AIAssistantTurnService.looksLikeUnfulfilledIntent(text))
    }

    @Test("Empty and whitespace-only content is not an announcement")
    func blankIsNotAnAnnouncement() {
        // Blank content is the *other* failure mode; the fallback chain demotes
        // it before the turn loop ever sees it. Nudging here would double-charge
        // a turn that is already being retried a rung down.
        #expect(!AIAssistantTurnService.looksLikeUnfulfilledIntent(nil))
        #expect(!AIAssistantTurnService.looksLikeUnfulfilledIntent(""))
        #expect(!AIAssistantTurnService.looksLikeUnfulfilledIntent("   \n\t "))
    }

    @Test("A long answer that merely mentions a lookup is not an announcement")
    func longAnswerIsNotAnAnnouncement() {
        let text = """
        Your spending is up this month. Let me check the categories: groceries \
        came to €410, transport €180, and eating out €260. The rise is almost \
        entirely eating out, which nearly doubled against your June baseline of \
        €135 and is now your second-largest category after groceries.
        """
        #expect(!AIAssistantTurnService.looksLikeUnfulfilledIntent(text))
    }
}
