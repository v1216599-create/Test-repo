name: Multi-Subscription AKS Health Check

on:
  schedule:
    - cron: "0 3 * * *"      # Daily 8:30 AM IST
  workflow_dispatch:          # Manual trigger

jobs:
  aks-health:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Azure Login
        uses: azure/login@v2
        with:
          creds: >
            {
              "clientId": "${{ secrets.AZURE_CLIENT_ID }}",
              "clientSecret": "${{ secrets.AZURE_CLIENT_SECRET }}",
              "tenantId": "${{ secrets.AZURE_TENANT_ID }}",
              "subscriptionId": "${{ secrets.AZURE_SUBSCRIPTION_ID }}"
            }

      - name: Install tools (kubectl + jq)
        run: |
          sudo az aks install-cli
          sudo apt-get update -y
          sudo apt-get install -y jq

      - name: Run AKS Multi-Subscription Health Scan
        run: |
          chmod +x /aks_health_all_subs.sh
          ./aks_health_all_subs.sh

      - name: Upload HTML Reports
        uses: actions/upload-artifact@v4
        with:
          name: aks-health-reports
          path: reports/
