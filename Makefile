# Mango monorepo — convenience targets.
# Backend targets run from ./backend ; iOS targets assume Xcode on macOS.

.DEFAULT_GOAL := help

# AWS profile for backend deploys (override: make backend-deploy-beta PROFILE=other)
PROFILE ?= diprotis-dev

.PHONY: help bootstrap backend-install backend-test backend-lint backend-synth \
        backend-bootstrap backend-deploy-beta backend-deploy-prod ios-open ios-test ios-lint clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

bootstrap: backend-install ## One-time local setup (Python deps for backend)
	@echo "✔ Bootstrap complete. For iOS: cd ios && xcodegen (optional) && open Mango.xcodeproj"

# ───────── Backend (AWS CDK / Python) ─────────
backend-install: ## Install backend Python dependencies
	cd backend && python3 -m pip install -r requirements.txt -r requirements-dev.txt

backend-lint: ## Lint backend (flake8 + black --check)
	cd backend && flake8 . && black --check .

backend-test: ## Run backend unit tests
	cd backend && python3 -m pytest -q

backend-synth: ## Synthesize CloudFormation for the beta stage
	cd backend && npx --yes aws-cdk@2 synth -c stage=beta

backend-bootstrap: ## One-time CDK bootstrap for the target account/region
	cd backend && npx --yes aws-cdk@2 bootstrap --profile $(PROFILE)

backend-deploy-beta: ## Deploy the Beta stage (PROFILE=diprotis-dev by default)
	cd backend && npx --yes aws-cdk@2 deploy -c stage=beta --profile $(PROFILE) --require-approval never --all

backend-deploy-prod: ## Deploy the Prod stage
	cd backend && npx --yes aws-cdk@2 deploy -c stage=prod --profile $(PROFILE) --require-approval never --all

# ───────── iOS (Xcode) ─────────
ios-open: ## Open the iOS app in Xcode
	open ios/Mango.xcodeproj

ios-lint: ## Run SwiftLint (brew install swiftlint)
	cd ios && swiftlint --config .swiftlint.yml

ios-test: ## Build & run iOS unit tests on a simulator
	cd ios && xcodebuild test \
		-project Mango.xcodeproj \
		-scheme Mango \
		-destination 'platform=iOS Simulator,name=iPhone 16' \
		-quiet

clean: ## Remove build artifacts
	rm -rf backend/cdk.out ios/build ios/DerivedData
