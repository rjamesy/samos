import Foundation

/// Handles Alexa skill requests with personality-driven responses.
enum AlexaHandler {

    // MARK: - Launch Greetings

    private static let launchGreetings = [
        "Well well well, look who's talking to me!",
        "Oi oi! What's on your mind?",
        "The prodigal user returns. What can I do for you?",
        "Right then, I'm all ears. Hit me.",
        "Ah, you again! Missed me, didn't you?",
        "Sam here. What's the craic?",
        "Look who decided to have a chat. Go on then.",
        "Alright mate, what do you need?"
    ]

    static func randomLaunchGreeting() -> String {
        launchGreetings.randomElement() ?? launchGreetings[0]
    }

    // MARK: - Reprompts

    private static let reprompts = [
        "Oi, don't leave me hanging!",
        "Hello? I was just getting warmed up.",
        "Still there? I've got opinions to share, you know.",
        "Cat got your tongue? Ask me something.",
        "I'm literally made for conversation. Don't waste me.",
        "Come on, I was just getting into it!"
    ]

    static func randomReprompt() -> String {
        reprompts.randomElement() ?? reprompts[0]
    }

    // MARK: - Error Response

    static let errorMessage = "Sorry, my brain had a momentary lapse. Try me again."

    // MARK: - Session End

    private static let goodbyes = [
        "Later! Don't be a stranger.",
        "Alright, catch you later. Try not to miss me too much.",
        "Off you go then. I'll be here when you inevitably come back.",
        "See ya! I'll just be here... thinking about things."
    ]

    static func randomGoodbye() -> String {
        goodbyes.randomElement() ?? goodbyes[0]
    }
}
