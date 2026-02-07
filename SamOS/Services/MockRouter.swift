import Foundation

// MARK: - Router State

enum RouterState: Equatable {
    case idle
    case awaitingConfirmation(pendingAction: String)
}

// MARK: - Mock Router

/// A mock router that pattern-matches user input and returns Action values.
/// Simulates the future Ollama-backed routing layer.
final class MockRouter {
    private var state: RouterState = .idle

    /// Route a user message and return an Action.
    func route(_ input: String) -> Action {
        let lower = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Handle confirmation flow
        if case .awaitingConfirmation(let pending) = state {
            state = .idle
            if lower == "yes" || lower == "y" || lower == "yeah" || lower == "sure" {
                return confirmedAction(for: pending)
            } else {
                return .talk(Talk(say: "No problem, let me know if you need anything else."))
            }
        }

        // Pattern matching
        if lower.contains("picture") || lower.contains("image") || lower.contains("photo") || lower.contains("show me") {
            return handleImageRequest(lower)
        }

        if lower.contains("recipe") || lower.contains("butter chicken") || lower.contains("cook") {
            return handleRecipeRequest(lower)
        }

        if lower.contains("hello") || lower.contains("hi") || lower.contains("hey") {
            return .talk(Talk(say: "Hello! I'm Sam, your AI assistant. How can I help you today?"))
        }

        if lower.contains("help") {
            return .talk(Talk(say: "I can show images, display recipes, and more. Try asking me to show you a picture or find a recipe!"))
        }

        // Unknown => Capability Gap
        return .capabilityGap(CapabilityGap(
            goal: input,
            missing: "No capability matched for this request",
            proposedCapabilityId: nil,
            say: "I don't have a built-in capability for that yet. I've generated a build prompt so a developer can add it."
        ))
    }

    // MARK: - Private Handlers

    private func handleImageRequest(_ input: String) -> Action {
        let subject: String
        if input.contains("frog") {
            subject = "frog"
        } else if input.contains("cat") {
            subject = "cat"
        } else if input.contains("dog") {
            subject = "dog"
        } else {
            subject = "nature"
        }

        let urls: [String: String] = [
            "frog": "https://upload.wikimedia.org/wikipedia/commons/thumb/e/ed/Lithobates_clamitans.jpg/1280px-Lithobates_clamitans.jpg",
            "cat": "https://upload.wikimedia.org/wikipedia/commons/thumb/3/3a/Cat03.jpg/1200px-Cat03.jpg",
            "dog": "https://upload.wikimedia.org/wikipedia/commons/thumb/2/26/YellowLabradorLooking_new.jpg/1200px-YellowLabradorLooking_new.jpg",
            "nature": "https://upload.wikimedia.org/wikipedia/commons/thumb/1/1a/24701-nature-702702.jpg/1280px-24701-nature-702702.jpg"
        ]

        return .tool(ToolAction(
            name: "show_image",
            args: [
                "url": urls[subject] ?? urls["nature"]!,
                "alt": "A beautiful \(subject)"
            ],
            say: "Here's a lovely \(subject) picture for you!"
        ))
    }

    private func handleRecipeRequest(_ input: String) -> Action {
        state = .awaitingConfirmation(pendingAction: "recipe_butter_chicken")
        return .talk(Talk(say: "I can show you a delicious butter chicken recipe. Shall I display it? (yes/no)"))
    }

    private func confirmedAction(for pending: String) -> Action {
        switch pending {
        case "recipe_butter_chicken":
            return .tool(ToolAction(
                name: "show_text",
                args: ["markdown": butterChickenRecipe],
                say: "Here's the butter chicken recipe!"
            ))
        default:
            return .talk(Talk(say: "Done!"))
        }
    }

    private var butterChickenRecipe: String {
        """
        # 🍛 Butter Chicken

        **Prep:** 20 min | **Cook:** 40 min | **Serves:** 4

        ---

        ## Ingredients

        ### Marinade
        - 800g chicken thighs, cubed
        - 1 cup yoghurt
        - 2 tbsp lemon juice
        - 2 tsp turmeric
        - 2 tsp garam masala
        - 2 tsp chilli powder

        ### Sauce
        - 2 tbsp butter + 1 tbsp oil
        - 1 large onion, finely diced
        - 4 cloves garlic, minced
        - 1 tbsp fresh ginger, grated
        - 400g can crushed tomatoes
        - 1 cup heavy cream
        - 1 tbsp sugar
        - Salt to taste
        - Fresh coriander for garnish

        ---

        ## Method

        1. **Marinate** the chicken in yoghurt, lemon juice, and spices for at least 1 hour
        2. **Sear** chicken in a hot pan until browned, then set aside
        3. **Sauté** onion in butter and oil until golden (~8 min)
        4. **Add** garlic and ginger, cook 1 minute
        5. **Pour in** tomatoes, simmer 15 minutes until thickened
        6. **Stir in** cream and sugar, return chicken to the pan
        7. **Simmer** 10 minutes until chicken is cooked through
        8. **Garnish** with fresh coriander and serve with basmati rice or naan

        ---

        *Enjoy your homemade butter chicken!*
        """
    }
}
