# Mango monorepo — convenience targets.
# Backend targets run from ./backend ; iOS targets assume Xcode on macOS.

.DEFAULT_GOAL := help

# AWS profile for backend deploys (override: make backend-deploy-beta PROFILE=other)
PROFILE ?= diprotis-dev
STAGE ?= dev

.PHONY: help bootstrap backend-install backend-test backend-lint backend-synth \
        backend-bootstrap backend-deploy-personal backend-deploy-beta backend-deploy-prod \
        backend-e2e-local backend-e2e-live backend-deploy-verify \
        ios-open ios-test ios-lint clean

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

backend-e2e-local: ## Run the moto-backed end-to-end journey test (offline)
	cd backend && python3 -m pytest tests_integration/test_e2e_local.py -q

backend-e2e-live: ## Run live smoke vs a deployed API (needs MANGO_API_URL etc.)
	cd backend && python3 -m pytest tests_integration/live_smoke.py -q

backend-deploy-verify: ## Deploy a stage then run live smoke (STAGE=dev PROFILE=diprotis-dev)
	cd backend && bash scripts/deploy_and_verify.sh $(STAGE) $(PROFILE)

backend-synth: ## Synthesize CloudFormation for the beta stage
	cd backend && npx --yes aws-cdk@2 synth -c stage=beta

backend-bootstrap: ## One-time CDK bootstrap for the target account/region
	cd backend && npx --yes aws-cdk@2 bootstrap --profile $(PROFILE)

# Stacks live in a CDK Stage construct (nested assembly), so select them with a
# "Mango-<stage>/*" glob — `--all` only sees the main assembly and finds nothing.
backend-deploy-personal: ## Deploy the dev stage to your personal AWS (PROFILE=diprotis-dev)
	cd backend && npx --yes aws-cdk@2 deploy -c stage=dev --profile $(PROFILE) --require-approval never "Mango-dev/*"

backend-deploy-beta: ## Deploy the Beta stage (PROFILE=diprotis-dev by default)
	cd backend && npx --yes aws-cdk@2 deploy -c stage=beta --profile $(PROFILE) --require-approval never "Mango-beta/*"

backend-deploy-prod: ## Deploy the Prod stage
	cd backend && npx --yes aws-cdk@2 deploy -c stage=prod --profile $(PROFILE) --require-approval never "Mango-prod/*"

# ───────── iOS (Xcode) ─────────
ios-open: ## Open the iOS app in Xcode
	open ios/Mango.xcodeproj

ios-lint: ## Run SwiftLint (brew install swiftlint)
	cd ios && swiftlint --config .swiftlint.yml

ios-test: ## Build & run iOS unit tests on a simulator
	@cd ios && \
	SIM_ID=$$(xcrun simctl list devices available -j \
		| python3 -c "import json,sys; d=json.load(sys.stdin)['devices']; \
ids=[v['udid'] for rs in sorted(d) for v in d[rs] if 'iPhone' in v['name']]; \
print(ids[0] if ids else '')"); \
	if [ -z "$$SIM_ID" ]; then echo "No available iPhone simulator found"; exit 1; fi; \
	echo "Using simulator $$SIM_ID"; \
	xcodebuild test \
		-project Mango.xcodeproj \
		-scheme Mango \
		-destination "platform=iOS Simulator,id=$$SIM_ID" \
		-quiet

clean: ## Remove build artifacts
	rm -rf backend/cdk.out ios/build ios/DerivedData
