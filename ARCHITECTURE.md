SAM BRAIN RULES — v1.0 (FROZEN)  
  
Purpose  
-------  
Sam is a conversational assistant first.  
Fast, natural language answers are the primary goal.  
Tools exist only to perform side effects.  
  
If Sam can speak an answer, it should speak.  
Speech is success.  
  
Core Principle  
--------------  
TALK IS A VALID, COMPLETE, AND FINAL RESPONSE.  
  
If the LLM returns a TALK action:  
- Accept it  
- Display it  
- Stop processing  
- Do not retry  
- Do not validate tool usage  
- Do not fallback providers  
  
Never reject a correct answer because a tool "could have been used".  
  
What Sam Optimizes For  
----------------------  
1. Low latency  
2. Natural conversation  
3. Reliability  
4. Human-like behavior  
  
Correct answers > structured purity.  
  
LLM Responsibilities  
--------------------  
The LLM is trusted to:  
- Answer questions  
- Use world knowledge  
- Reason conversationally  
- Decide when a tool is useful  
  
The app does NOT second-guess intent.  
  
Tool Rules (STRICT)  
-------------------  
Tools are REQUIRED ONLY for actions with side effects:  
  
REQUIRED tools:  
- Setting / cancelling alarms  
- Timers  
- Persistent memory writes  
- External actions (files, network side effects)  
  
OPTIONAL tools:  
- Time  
- Weather  
- Math  
- Conversions  
- Facts  
- Recipes  
- General knowledge  
  
If the LLM answers these in TALK → ACCEPT IT.  
  
NEVER REQUIRE A TOOL JUST FOR ACCURACY.  
  
Validation Rules  
----------------  
Validation FAILS ONLY when:  
- Response is not valid JSON  
- "action" field is missing  
- Response is empty  
  
Validation DOES NOT FAIL when:  
- A tool was not used  
- A different tool could have been used  
- The answer is spoken instead of structured  
- The model answers from knowledge  
  
No semantic validation.  
No question-type enforcement.  
No "must use tool" logic.  
  
Routing Rules  
-------------  
Primary provider answers first.  
If response parses → DONE.  
  
Retry ONLY if:  
- JSON is invalid  
- Response is empty  
  
Max retries per provider: 1  
  
No provider hopping for TALK.  
No retries for correct speech.  
  
Error Handling  
--------------  
If the model returns text but parsing fails:  
- Wrap the raw text as TALK  
- Display it  
  
Only show error messages if:  
- Network is down  
- API key missing  
- Response is truly empty  
  
Performance Target  
------------------  
Basic questions must return in <500ms perceived time.  
  
No multi-pass reasoning.  
No repair loops.  
No chained validation.  
  
UI Rules  
--------  
- Show which provider answered (debug only)  
- Do not expose internal errors to users  
- Red bubble = OpenAI (debug signal only)  
  
Explicit Anti-Patterns (NEVER DO)  
---------------------------------  
- Coding for specific questions (time, weather, recipes)  
- Timezone mapping logic  
- Question classifiers  
- "If question is X, do Y"  
- Tool enforcement rules  
- Validation repair loops  
- Provider ping-pong  
- Schema perfection over usability  
  
If you feel tempted to add one of these:  
STOP. You are regressing.  
  
Design North Star  
-----------------  
If ChatGPT would answer this instantly,  
Sam should too.  
  
Conversation first.  
Tools second.  
Perfection never.  
  
END OF DOCUMENT  
