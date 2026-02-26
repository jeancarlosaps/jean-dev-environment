#!/bin/bash
# ==========================================
# Mac Dev Setup Script
# Author: Jean Carlos Pereira
# Description: Setup ZSH, Powerlevel10k,
# autosuggestions, syntax highlight and fzf
# ==========================================

set -e

echo "🚀 Starting macOS Dev Environment Setup..."

# ================================
# CHECK BREW
# ================================
if ! command -v brew &> /dev/null; then
  echo "❌ Homebrew not found. Install it first: https://brew.sh"
  exit 1
fi

echo "✅ Homebrew found"

# ================================
# INSTALL PACKAGES IF NOT INSTALLED
# ================================
install_if_missing() {
  if brew list "$1" &>/dev/null; then
    echo "✔ $1 already installed"
  else
    echo "📦 Installing $1..."
    brew install "$1"
  fi
}

install_if_missing zsh-autosuggestions
install_if_missing zsh-syntax-highlighting
install_if_missing fzf
install_if_missing powerlevel10k

# ================================
# INSTALL FZF INTEGRATION
# ================================
if [ ! -f ~/.fzf.zsh ]; then
  echo "⚙️ Configuring FZF..."
  $(brew --prefix)/opt/fzf/install --all
fi

# ================================
# BACKUP ZSHRC
# ================================
if [ ! -f ~/.zshrc.backup ]; then
  cp ~/.zshrc ~/.zshrc.backup 2>/dev/null || true
  echo "🛟 Backup created at ~/.zshrc.backup"
fi

# ================================
# APPEND CONFIG BLOCK IF NOT EXISTS
# ================================
if ! grep -q "# JEAN DEV ENV BLOCK" ~/.zshrc 2>/dev/null; then
  echo "📝 Updating ~/.zshrc..."

  cat << 'EOF' >> ~/.zshrc

# ================================
# JEAN DEV ENV BLOCK
# ================================

# Powerlevel10k
source $(brew --prefix)/share/powerlevel10k/powerlevel10k.zsh-theme

# Autosuggestions
source $(brew --prefix)/share/zsh-autosuggestions/zsh-autosuggestions.zsh

# Syntax Highlight
source $(brew --prefix)/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# FZF
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

# Aliases
alias gs="git status"
alias gc="git commit -m"
alias gp="git push"
alias gl="git pull"
alias gco="git checkout"
alias ..="cd .."
alias ...="cd ../.."
alias brewup="brew update && brew upgrade"

# ================================
EOF

else
  echo "✔ Config block already exists in .zshrc"
fi

echo "🔄 Reloading shell..."
exec zsh
