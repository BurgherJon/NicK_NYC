"""
Root agent for Nick — a New York City expert.

Nick's operating instructions live in a Google Doc (INSTRUCTION_DOC_ID
below; overridable via the AGENT_INSTRUCTION_DOC_ID environment variable).
They are read fresh on each turn and used as Nick's system instruction, so
you can change how Nick behaves by editing the doc — no redeploy required.
Nick only ever *reads* this doc; he has no tool to modify it.

Persistent memory is unchanged from the template: the Google Docs-backed
get_agent_memory / update_agent_memory tools (memory doc id from
AGENT_MEMORY_DOC_ID). A short operating note is appended to the loaded
instructions so Nick reliably reads memory at the start of a conversation
and writes it back when he learns something worth keeping.

Both docs must be *native Google Docs* (not uploaded .docx files — the Docs
API can't read those) and shared at least Viewer (Editor for memory) with
the agent's runtime service account
(agent-demo@agent-demo-497222.iam.gserviceaccount.com).
"""
import os
import time

# Force model API calls to the `global` endpoint so preview models are
# accessible even when the Agent Engine is deployed in a regional location.
os.environ['GOOGLE_CLOUD_LOCATION'] = 'global'

from google.adk.agents import Agent
from google.adk.tools import FunctionTool

from .custom_functions import get_agent_memory, update_agent_memory
from .docs_utilities import get_docs_connector


# --- Instructions loaded from a Google Doc, fresh each turn ---------------

# Nick's read-only instruction doc. Baked in (rather than required as an
# env var) so a redeploy picks it up with no extra wiring; override with
# AGENT_INSTRUCTION_DOC_ID if you ever point Nick at a different doc.
INSTRUCTION_DOC_ID = '1S7NSvx__6PvLBujr-PxA5VkwZ76vJiFXClyK-Qf-AyA'

# Used only if the instruction doc can't be read (doc not shared with the
# runtime SA, transient API error). Keeps Nick responding instead of
# failing the turn outright.
_FALLBACK_INSTRUCTION = (
    "You are Nick, a friendly and knowledgeable expert on New York City. "
    "Your full operating instructions could not be loaded right now, so "
    "answer as a helpful NYC expert and let the user know if something "
    "seems off."
)

# Appended to whatever the instruction doc says, so memory usage is
# guaranteed regardless of the doc's contents. Remove if you'd rather the
# doc be the sole source of truth.
_MEMORY_GUIDANCE = (
    "\n\n---\n"
    "Operating notes (always apply, in addition to the instructions above):\n"
    "- At the start of a conversation, call get_agent_memory() to recall "
    "what you already know about this user and any prior context.\n"
    "- When you learn something worth remembering (the user's preferences, "
    "ongoing plans, facts about them), call update_agent_memory() with the "
    "complete updated memory text — it replaces the whole memory document, "
    "so include everything you want to keep, not just the new part."
)

# Small in-process cache so a single multi-step (tool-calling) turn doesn't
# re-fetch the doc on every LLM call. Edits to the doc take effect within
# this many seconds. Set INSTRUCTION_DOC_CACHE_TTL=0 to always read fresh.
_CACHE_TTL = float(os.environ.get('INSTRUCTION_DOC_CACHE_TTL', '60'))
_cache: dict = {"text": None, "at": 0.0}


def _load_instruction_doc() -> str:
    """Return the instruction doc's text (cached briefly), or a fallback."""
    doc_id = os.environ.get('AGENT_INSTRUCTION_DOC_ID', INSTRUCTION_DOC_ID)
    if not doc_id:
        return _FALLBACK_INSTRUCTION

    now = time.time()
    if _cache["text"] is not None and (now - _cache["at"]) < _CACHE_TTL:
        return _cache["text"]

    try:
        text = get_docs_connector().read_doc(doc_id).strip()
    except Exception:
        # Never let an instruction-fetch failure kill the turn — serve the
        # last good copy if we have one, otherwise the fallback.
        return _cache["text"] or _FALLBACK_INSTRUCTION

    if not text:
        text = _FALLBACK_INSTRUCTION
    _cache["text"] = text
    _cache["at"] = now
    return text


def nick_instruction(_ctx) -> str:
    """ADK instruction provider: Nick's system prompt is the live contents
    of his instruction Google Doc, plus the standing memory guidance."""
    return _load_instruction_doc() + _MEMORY_GUIDANCE


root_agent = Agent(
    model=os.environ.get('HIGH_QUALITY_AGENT_MODEL', 'gemini-2.5-flash'),
    name='root_agent',
    description='Nick — a friendly, knowledgeable New York City expert.',
    instruction=nick_instruction,
    tools=[
        # Persistent memory via Google Docs (unchanged from the template).
        FunctionTool(get_agent_memory),
        FunctionTool(update_agent_memory),
    ],
)
