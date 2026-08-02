package cli

import "github.com/charmbracelet/lipgloss"

// Shared lipgloss styles for CLI output.
var (
	headerStyle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("212"))
	idStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color("244"))
	borderStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("240"))
	titleStyle  = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("86"))
	hintStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("244"))
	okStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color("42"))
)
