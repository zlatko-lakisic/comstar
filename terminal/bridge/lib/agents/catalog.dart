/// Curated AO stock agents exposed in COMSTAR Admin + Reach allowlists.
library;

class CuratedAgent {
  const CuratedAgent({
    required this.id,
    required this.label,
    required this.provider,
  });

  final String id;
  final String label;

  /// `openai` | `anthropic` | `ollama`
  final String provider;

  bool get needsSecret => provider == 'openai' || provider == 'anthropic';
}

/// Locked pack from the dynamic-planning plan.
const kCuratedAgents = <CuratedAgent>[
  CuratedAgent(
    id: 'gpt_research',
    label: 'GPT Research',
    provider: 'openai',
  ),
  CuratedAgent(
    id: 'gpt_reason',
    label: 'GPT Reason',
    provider: 'openai',
  ),
  CuratedAgent(
    id: 'gpt_write',
    label: 'GPT Write',
    provider: 'openai',
  ),
  CuratedAgent(
    id: 'claude_research',
    label: 'Claude Research',
    provider: 'anthropic',
  ),
  CuratedAgent(
    id: 'claude_reason',
    label: 'Claude Reason',
    provider: 'anthropic',
  ),
  CuratedAgent(
    id: 'claude_write',
    label: 'Claude Write',
    provider: 'anthropic',
  ),
  CuratedAgent(
    id: 'ollama_qwen2_5_14b_instruct',
    label: 'Qwen 2.5 14B (local)',
    provider: 'ollama',
  ),
];

const kCuratedAgentIds = <String>[
  'gpt_research',
  'gpt_reason',
  'gpt_write',
  'claude_research',
  'claude_reason',
  'claude_write',
  'ollama_qwen2_5_14b_instruct',
];

CuratedAgent? curatedAgentById(String id) {
  for (final a in kCuratedAgents) {
    if (a.id == id) return a;
  }
  return null;
}
