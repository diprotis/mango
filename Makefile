.PHONY: help install install-uv test lint format clean deploy-beta deploy-prod synth diff shell

help:
	@echo "Available commands:"
	@echo "  install-uv    Install uv package manager"
	@echo "  install       Install dependencies with uv"
	@echo "  shell         Activate virtual environment"
	@echo "  test          Run tests"
	@echo "  lint          Run linters"
	@echo "  format        Format code"
	@echo "  clean         Clean build artifacts"
	@echo "  synth         Synthesize CDK stacks"
	@echo "  diff          Show CDK diff"
	@echo "  deploy-beta   Deploy to Beta environment"
	@echo "  deploy-prod   Deploy to Production environment"
	@echo "  ci-local      Run local CI pipeline"
	@echo "  git-init      Initialize git repository"

install-uv:
	@if ! command -v uv &> /dev/null; then \
		echo "Installing uv..."; \
		curl -LsSf https://astral.sh/uv/install.sh | sh; \
	else \
		echo "uv is already installed: $$(uv --version)"; \
	fi

install: install-uv
	uv venv --python 3.10
	uv pip install -r infrastructure/requirements.txt
	uv pip install -r infrastructure/requirements-dev.txt
	pre-commit install

install-sync: install-uv
	uv pip sync infrastructure/requirements.txt infrastructure/requirements-dev.txt

update-deps:
	uv pip compile infrastructure/requirements.in -o infrastructure/requirements.txt
	uv pip compile infrastructure/requirements-dev.in -o infrastructure/requirements-dev.txt

shell:
	@echo "Activating virtual environment..."
	@echo "Run: source .venv/bin/activate"
	@bash -c "source .venv/bin/activate && exec bash"

test:
	pytest tests/ -v

test-unit:
	pytest tests/unit/ -v

test-integration:
	pytest tests/integration/ -v -m "$(STAGE)"

lint:
	flake8 infrastructure/ src/ tests/
	mypy infrastructure/ src/
	black --check infrastructure/ src/ tests/

format:
	black infrastructure/ src/ tests/

clean:
	rm -rf cdk.out/
	rm -rf .pytest_cache/
	rm -rf htmlcov/
	rm -rf .coverage
	find . -type d -name __pycache__ -exec rm -rf {} +
	find . -type f -name "*.pyc" -delete

synth:
	cd infrastructure && cdk synth

diff-beta:
	cd infrastructure && cdk diff -c stage=beta

diff-prod:
	cd infrastructure && cdk diff -c stage=prod

deploy-beta:
	cd infrastructure && cdk deploy --all -c stage=beta --require-approval never

deploy-prod:
	cd infrastructure && cdk deploy --all -c stage=prod --require-approval any-change

bootstrap-beta:
	cd infrastructure && cdk bootstrap -c stage=beta

bootstrap-prod:
	cd infrastructure && cdk bootstrap -c stage=prod

# Development helpers
dev-install: install-uv
	uv venv --python 3.10
	uv pip install -e ".[dev]"

freeze:
	uv pip freeze > requirements-lock.txt

# Lambda layer creation helper
create-lambda-layer:
	python scripts/create_lambda_layer.py

create-lambda-layer-simple:
	mkdir -p lambda-layer/python
	uv pip install -r src/lambdas/requirements.txt --target lambda-layer/python
	cd lambda-layer && zip -r ../lambda-layer.zip .
	rm -rf lambda-layer

# Run local CI pipeline
ci-local:
	chmod +x scripts/ci-local.sh
	./scripts/ci-local.sh

# Initialize git repository
git-init:
	chmod +x scripts/init-git.sh
	./scripts/init-git.sh
