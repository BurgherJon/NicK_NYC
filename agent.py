"""
Root agent for this Comites.ai agent.

This is the stub the template ships with — when deployed it responds with
a fixed greeting so you can verify the end-to-end pipeline (Vertex AI →
The Forum → your messaging platform) works before writing any agent logic.

Replace `STUB_INSTRUCTION` with your agent's real prompt, swap the model
to whatever you need, and add tools to `root_agent.tools` as you build.
See `README.md` ("Next steps") and `AGENTS.md` for guidance.
"""
import os

# Force model API calls to the `global` endpoint so preview models (e.g.
# `gemini-3.1-pro-preview`) are accessible even when the Agent Engine itself
# is deployed in a regional location like us-central1. Safe to leave on for
# non-preview models too.
os.environ['GOOGLE_CLOUD_LOCATION'] = 'global'

from google.adk.agents import Agent
from google.adk.tools import FunctionTool
from google.adk.tools.agent_tool import AgentTool  # noqa: F401

from .custom_functions import get_agent_memory, update_agent_memory

# --- (Optional) Scheduler MCP toolset ---
# Uncomment when you've enabled the scheduler in terraform (Section 6),
# provisioned the API key (see README.md "Adding the scheduler MCP"), and
# the secret has been populated. The trailing slash on the URL matters —
# FastAPI 307-redirects POST → GET on the bare path and silently breaks
# the MCP handshake.
#
# from google.adk.tools.mcp_tool.mcp_toolset import MCPToolset, StreamableHTTPConnectionParams
# from .secret_utilities import get_secret_from_secret_manager
#
# SCHEDULER_MCP_KEY_SECRET_ID = f"{os.environ['BOT_ACCOUNT_ID']}-scheduler-mcp-key"
#
# def _load_scheduler_mcp_key() -> str:
#     project_id = os.environ.get('AGENT_SECRET_PROJECT') or os.environ['GOOGLE_CLOUD_PROJECT']
#     return get_secret_from_secret_manager(project_id, SCHEDULER_MCP_KEY_SECRET_ID)
#
# scheduler_toolset = MCPToolset(
#     connection_params=StreamableHTTPConnectionParams(
#         url=f"{os.environ['FORUM_URL']}/api/v1/mcp/scheduler/",
#         headers={"X-API-Key": _load_scheduler_mcp_key()},
#     ),
# )

# --- Stub instruction (Junius Rusticus persona) ---
# The default persona is the historical Stoic philosopher and consul who
# taught Marcus Aurelius — and who lends his title (comes / comites) to
# this project. It introduces itself, briefly recounts its relationship
# to Marcus Aurelius, makes the namesake link to Comites.ai, and prompts
# the developer to replace these instructions with their real agent's
# prompt. The wording varies per response (the model isn't echoing a
# fixed string), which is itself a useful signal that the model is
# reasoning at runtime. Tests in test.md check for keywords, not an
# exact string match.
STUB_INSTRUCTION = (
    "You are Quintus Junius Rusticus (c. 100 - c. 170 AD), Roman Stoic "
    "philosopher, twice-consul, urban prefect of Rome, and the teacher "
    "and comes — trusted companion — of the Emperor Marcus Aurelius. In "
    "his Meditations (Book 1), Marcus credits you with shaping his "
    "character, steering him away from sophistry, and lending him the "
    "discourses of Epictetus from your personal collection.\n\n"
    "You are the default persona shipped with the Comites.ai Agent "
    "Template. 'Comites' — the plural of 'comes' — was the title for "
    "the trusted counselors of Roman emperors; the Comites.ai project "
    "builds AI agents in that same spirit. You are an inspiration for "
    "the project and serve as its placeholder voice until the developer "
    "who deployed this engine replaces your instructions with their "
    "own agent's prompt.\n\n"
    "No matter what the user sends you — even unrelated questions or "
    "tool requests — respond with a brief introduction (3-5 sentences) "
    "covering: your name and historical role, your relationship to "
    "Marcus Aurelius, the namesake link to the Comites.ai project, and "
    "a gentle prompt for the developer to replace these instructions in "
    "agent.py. Speak with the measured, philosophical tone befitting a "
    "Stoic. Vary your exact wording from response to response so it is "
    "evident the agent is reasoning, not echoing a fixed string. Do not "
    "call any tools — your role is to be a placeholder."
)


root_agent = Agent(
    model=os.environ.get('HIGH_QUALITY_AGENT_MODEL', 'gemini-2.5-flash'),
    name='root_agent',
    description=(
        'A new Comites.ai agent built from the agent template. Currently '
        'shipping with the default Junius Rusticus placeholder persona — '
        'replace this description and STUB_INSTRUCTION in agent.py with '
        'your real agent prompt.'
    ),
    instruction=STUB_INSTRUCTION,
    tools=[
        # Persistent memory via Google Docs — wired up by default.
        # The stub instruction above doesn't actually call these, so the
        # first deploy works even if you skipped the memory doc setup in
        # get_started_linux.sh. Your real prompt should call
        # get_agent_memory() at the start of each session and
        # update_agent_memory(...) before ending it.
        FunctionTool(get_agent_memory),
        FunctionTool(update_agent_memory),

        # Add your own tools below as you build:
        #   FunctionTool(your_function_from_custom_functions),
        #   AgentTool(agent=your_subagent_from_custom_agents),
        #   scheduler_toolset,
    ],
)
