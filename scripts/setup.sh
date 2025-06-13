#!/bin/bash

# Setup script for Reading Journey Backend using uv
set -e

echo "🚀 Setting up Reading Journey Backend development environment with uv..."

# Check if uv is installed
if ! command -v uv &> /dev/null; then
    echo "📦 Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.cargo/bin:$PATH"
    echo "✅ uv installed successfully"
fi

echo "✅ uv version: $(uv --version)"

# Check Python version
if ! uv python list | grep -q "3.10"; then
    echo "📦 Installing Python 3.10 with uv..."
    uv python install 3.10
fi

# Check Node.js (for CDK)
if ! command -v node &> /dev/null; then
    echo "❌ Node.js is required for AWS CDK. Please install Node.js 16 or higher."
    exit 1
fi

echo "✅ Node.js version: $(node --version)"

# Create virtual environment with uv
echo "📦 Creating Python virtual environment with uv..."
uv venv --python 3.10

# Activate virtual environment
echo "📦 Activating virtual environment..."
source .venv/bin/activate

# Install dependencies with uv
echo "📦 Installing Python dependencies with uv..."
uv pip install -r infrastructure/requirements.txt
uv pip install -r infrastructure/requirements-dev.txt

# Install AWS CDK globally
echo "📦 Installing AWS CDK..."
npm install -g aws-cdk@latest

# Install pre-commit hooks
echo "🔧 Setting up pre-commit hooks..."
pre-commit install

# Create .env file if it doesn't exist
if [ ! -f .env ]; then
    cp .env.example .env
fi

# Create necessary directories
echo "📁 Creating directory structure..."
mkdir -p tests/unit
mkdir -p tests/integration
mkdir -p src/lambdas
mkdir -p docs
touch src/__init__.py
touch src/lambdas/__init__.py
touch tests/__init__.py

# Make scripts executable
echo "🔧 Making scripts executable..."
chmod +x scripts/*.sh
chmod +x scripts/*.py 2>/dev/null || true

echo ""
echo "✨ Setup complete! Next steps:"
echo ""
echo "1. Activate the virtual environment:"
echo "   source .venv/bin/activate"
echo ""
echo "2. Configure AWS credentials if not already done:"
echo "   aws configure"
echo ""
echo "3. Update the config files with your AWS account ID:"
echo "   - infrastructure/config/beta.json"
echo "   - infrastructure/config/prod.json"
echo ""
echo "Happy coding! 🎉"
