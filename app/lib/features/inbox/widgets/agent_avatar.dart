import 'package:flutter/material.dart';

/// Brand identity for a coding agent — an optional bundled logo, a brand color,
/// and a display label. Herdr normalizes the agent kind into `agent` (e.g.
/// "claude", "codex", "gemini"), which is what we key on.
class AgentBrand {
  const AgentBrand({this.asset, required this.color, required this.label});

  final String? asset;
  final Color color;
  final String label;
}

/// Known coding agents. Logos are bundled under `assets/agents/` as they're
/// added; until an agent has one, it falls back to a branded initial.
const _brands = <String, AgentBrand>{
  'claude': AgentBrand(
    asset: 'assets/agents/claude.png',
    color: Color(0xFFD97757),
    label: 'Claude',
  ),
  'codex': AgentBrand(color: Color(0xFF10A37F), label: 'Codex'),
  'gemini': AgentBrand(color: Color(0xFF4285F4), label: 'Gemini'),
  'cursor': AgentBrand(color: Color(0xFF9AA0A6), label: 'Cursor'),
  'copilot': AgentBrand(color: Color(0xFF8957E5), label: 'Copilot'),
  'aider': AgentBrand(color: Color(0xFF14B8A6), label: 'Aider'),
  'amp': AgentBrand(color: Color(0xFFF59E0B), label: 'Amp'),
  'cline': AgentBrand(color: Color(0xFF6366F1), label: 'Cline'),
};

AgentBrand brandFor(String agent) =>
    _brands[agent.toLowerCase()] ??
    AgentBrand(color: const Color(0xFF7C8B93), label: agent);

/// A round avatar for an agent: its logo if we have one, otherwise a branded
/// initial on a tinted disc.
class AgentAvatar extends StatelessWidget {
  const AgentAvatar({super.key, required this.agent, this.radius = 20});

  final String agent;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brand = brandFor(agent);

    if (brand.asset != null) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: scheme.surfaceContainerHighest,
        child: Padding(
          padding: EdgeInsets.all(radius * 0.42),
          child: Image.asset(brand.asset!, fit: BoxFit.contain),
        ),
      );
    }

    final initial = brand.label.isEmpty ? '?' : brand.label[0].toUpperCase();
    return CircleAvatar(
      radius: radius,
      backgroundColor: Color.alphaBlend(
        brand.color.withValues(alpha: 0.22),
        scheme.surfaceContainerHighest,
      ),
      child: Text(
        initial,
        style: TextStyle(
          color: brand.color,
          fontWeight: FontWeight.w700,
          fontSize: radius * 0.85,
        ),
      ),
    );
  }
}
