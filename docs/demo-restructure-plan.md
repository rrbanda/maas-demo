# Demo Narrative Restructure Plan

## Personas (from RHOAI 3.4 MaaS Documentation)

### 1. Cluster Administrator
**Responsibilities:**
- Enable MaaS in OpenShift AI operator
- Configure underlying cluster infrastructure
- Scale MaaS components
- Apply software updates

**Screenshots needed:**
- [ ] DataScienceCluster with `modelsAsService: Managed`
- [ ] Kuadrant/RHCL operator installed
- [ ] MaaS pods running in redhat-ods-applications

### 2. OpenShift AI Administrator  
**Responsibilities:**
- Define governance structure (subscriptions, authorization policies)
- Assign users to groups
- Configure model quota and token limits
- Manage API keys for external consumers
- Monitor usage metrics

**Screenshots needed:**
- [ ] OpenShift Console: MaaSSubscription list
- [ ] OpenShift Console: Create/edit subscription
- [ ] OpenShift Console: MaaSAuthPolicy
- [ ] RHOAI Dashboard: Admin view of subscriptions (if available)
- [ ] Observability dashboard (usage metrics)

### 3. User / Developer / Data Scientist
**Responsibilities:**
- Find available models
- View their subscription and access level
- Generate API keys (temporary or persistent)
- Make API calls to models
- Test models in playground or Jupyter

**Screenshots needed:**
- [x] 01-user-models-list.png - AI asset endpoints showing available models
- [x] 02-user-view-endpoint-apikey.png - View endpoint dialog with subscription selector
- [x] 03-user-apikey-generated.png - Generated ephemeral API key
- [ ] API Keys page (manage persistent keys)
- [ ] Playground (test model)

## New Demo Narrative Structure

### Part 1: Introduction (2 min)
- What is MaaS?
- Architecture diagram (AI Bridge pattern)
- Value proposition

### Part 2: Platform Setup (Cluster Admin) (3 min)
- MaaS enablement in DataScienceCluster
- Prerequisites verification (RHCL, PostgreSQL, Gateway)
- GitOps deployment via ArgoCD

### Part 3: Governance Configuration (AI Admin) (5 min)
- **Creating Subscriptions** - Define who gets access with what limits
- **Authorization Policies** - Grant model access to groups
- **Managing API Keys** - Admin can create/revoke keys for users

### Part 4: User Experience (Developer) (5 min)
- **Find Models** - Browse AI asset endpoints
- **View Subscription** - See your tier and limits
- **Generate API Key** - Get temporary or permanent key
- **Make API Calls** - Test with curl or SDK

### Part 5: Advanced Capabilities (5 min)
- **ExternalModels** - Route to remote clusters or cloud APIs
- **Rate Limiting Demo** - Show 429 when limit exceeded
- **Secret Rotation** - Vault + ESO pattern

### Appendices
- A: API Key Lifecycle (create, rotate, revoke)
- B: CLI commands reference
- C: Troubleshooting
