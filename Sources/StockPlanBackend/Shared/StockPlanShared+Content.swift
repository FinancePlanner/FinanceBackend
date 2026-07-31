import StockPlanShared
import Vapor

// MARK: - Common

extension APISuccess: @retroactive Content {}
extension APIMessageResponse: @retroactive Content {}
extension APIErrorResponse: @retroactive Content {}
extension APIEnvelope: @retroactive Content {}
extension EmptyAPIResponse: @retroactive Content {}

// MARK: - Auth

extension AuthLoginRequest: @retroactive Content {}
extension AuthResponse: @retroactive Content {}
extension AuthUserResponse: @retroactive Content {}
extension AuthForgotPasswordRequest: @retroactive Content {}
extension AuthForgotPasswordResponse: @retroactive Content {}
extension AuthResetPasswordRequest: @retroactive Content {}
extension AuthRefreshRequest: @retroactive Content {}

// MARK: - Stocks

extension StockRequest: @retroactive Content {}
extension SellStockRequest: @retroactive Content {}
extension StockResponse: @retroactive Content {}
extension PortfolioListRequest: @retroactive Content {}
extension PortfolioListResponse: @retroactive Content {}
extension WatchlistItemRequest: @retroactive Content {}
extension WatchlistItemUpdateRequest: @retroactive Content {}
extension WatchlistItemResponse: @retroactive Content {}
extension WatchlistListRequest: @retroactive Content {}
extension WatchlistListResponse: @retroactive Content {}
extension WatchlistStatus: @retroactive Content {}
extension ResearchNoteRequest: @retroactive Content {}
extension ResearchNoteResponse: @retroactive Content {}
extension PriceRange: @retroactive Content {}
extension StockValuationRequest: @retroactive Content {}
extension StockValuationDraft: @retroactive Content {}
extension StockHistory: @retroactive Content {}
extension StockNews: @retroactive Content {}
extension BulkStockRequest: @retroactive Content {}
extension BulkStockResultItem: @retroactive Content {}
extension BulkStockResponse: @retroactive Content {}
extension TargetRequest: @retroactive Content {}
extension TargetResponse: @retroactive Content {}

// Price Chart
extension PriceChartPoint: @retroactive Content {}
extension PriceChartSeries: @retroactive Content {}
extension PriceChartComparisonResponse: @retroactive Content {}

// MARK: - Dashboard

extension DashboardResponse: @retroactive Content {}
extension DashboardPerformerDTO: @retroactive Content {}
extension DashboardAllocationDTO: @retroactive Content {}

// MARK: - Portfolio

extension PortfolioSummaryResponse: @retroactive Content {}
extension PortfolioPerformanceResponse: @retroactive Content {}
extension PortfolioDividendsResponse: @retroactive Content {}
extension PortfolioSectorHoldingContribution: @retroactive Content {}
extension PortfolioSectorExposureItem: @retroactive Content {}
extension PortfolioSectorExposureResponse: @retroactive Content {}
extension DividendProjectedItem: @retroactive Content {}
extension DividendMonthlyBreakdown: @retroactive Content {}
extension TransactionResponse: @retroactive Content {}
extension LotResponse: @retroactive Content {}
extension PnlResponse: @retroactive Content {}
extension PortfolioCapabilities: @retroactive Content {}
extension Portfolio: @retroactive Content {}
extension PortfolioCreateRequest: @retroactive Content {}
extension PortfolioUpdateRequest: @retroactive Content {}
extension PortfolioCloneRequest: @retroactive Content {}
extension PortfolioPageResponse: @retroactive Content {}
extension PortfolioMembership: @retroactive Content {}
extension PortfolioInvitation: @retroactive Content {}
extension PortfolioInvitationCreateRequest: @retroactive Content {}
extension PortfolioInvitationAcceptRequest: @retroactive Content {}
extension PortfolioCashPosition: @retroactive Content {}
extension PortfolioCashPositionRequest: @retroactive Content {}
extension PortfolioAccountAssignmentRequest: @retroactive Content {}
extension PortfolioComparisonHolding: @retroactive Content {}
extension PortfolioComparisonColumn: @retroactive Content {}
extension PortfolioComparison: @retroactive Content {}

// MARK: - Portfolio Rebalancing

extension AllocationTargetLeaf: @retroactive Content {}
extension AllocationTargetBucket: @retroactive Content {}
extension AllocationModel: @retroactive Content {}
extension AllocationModelUpsertRequest: @retroactive Content {}
extension RebalancingValuationWarning: @retroactive Content {}
extension RebalancingAllocationRow: @retroactive Content {}
extension RebalancingOverview: @retroactive Content {}
extension RebalanceTradeOverride: @retroactive Content {}
extension RebalancingSimulationRequest: @retroactive Content {}
extension RebalanceTrade: @retroactive Content {}
extension RebalancingSimulation: @retroactive Content {}
extension RebalancePlanCreateRequest: @retroactive Content {}
extension RebalancePlan: @retroactive Content {}
extension RebalancePlanCompletionRequest: @retroactive Content {}
extension RebalancingHistorySummary: @retroactive Content {}
extension RebalancingAlert: @retroactive Content {}
extension RebalancingNotificationPreferences: @retroactive Content {}
extension UpdateRebalancingNotificationPreferencesRequest: @retroactive Content {}
extension AllocationModelBulkCopyRequest: @retroactive Content {}
extension AllocationModelBulkCopyResult: @retroactive Content {}
extension RebalancingDashboardSummary: @retroactive Content {}

// MARK: - Retirement Planning

extension RetirementPlanInput: @retroactive Content {}
extension RetirementPlan: @retroactive Content {}
extension RetirementPlanUpsertRequest: @retroactive Content {}
extension RetirementRulePack: @retroactive Content {}
extension RetirementProjectionRequest: @retroactive Content {}
extension RetirementProjectionPoint: @retroactive Content {}
extension RetirementProjectionSummary: @retroactive Content {}
extension RetirementProjection: @retroactive Content {}

// MARK: - Advanced Reporting

extension ReportTemplateInput: @retroactive Content {}
extension ReportTemplate: @retroactive Content {}
extension ReportTemplatePageResponse: @retroactive Content {}
extension ReportScheduleInput: @retroactive Content {}
extension ReportSchedule: @retroactive Content {}
extension ReportSchedulePageResponse: @retroactive Content {}
extension ReportRunCreateRequest: @retroactive Content {}
extension ReportRun: @retroactive Content {}
extension ReportRunPageResponse: @retroactive Content {}
extension ReportArtifactDownloadResponse: @retroactive Content {}

// MARK: - User Profile

extension GetUserProfileRequest: @retroactive Content {}
extension GetUserProfileResponse: @retroactive Content {}
extension UpdateUserProfileRequest: @retroactive Content {}
extension UpdateUserProfileResponse: @retroactive Content {}
extension UpdateUsernameRequest: @retroactive Content {}
extension UpdateEmailRequest: @retroactive Content {}
extension UpdatePasswordRequest: @retroactive Content {}
extension DeleteUserProfileRequest: @retroactive Content {}
extension DeleteUserProfileResponse: @retroactive Content {}

// MARK: - News & Earnings

extension NewsItemResponse: @retroactive Content {}
extension NewsSyncResponse: @retroactive Content {}
extension FinnhubNewsWebhookResponse: @retroactive Content {}
extension EarningsItemResponse: @retroactive Content {}
extension EarningsQueryRequest: @retroactive Content {}

// MARK: - Broker / CSV

extension CsvImportPreviewItem: @retroactive Content {}
extension CsvImportPreviewError: @retroactive Content {}
extension CsvImportPreviewResponse: @retroactive Content {}
extension CsvImportCommitResponse: @retroactive Content {}
extension WatchlistCsvImportPreviewItem: @retroactive Content {}
extension WatchlistCsvImportPreviewResponse: @retroactive Content {}
extension WatchlistCsvImportCommitResponse: @retroactive Content {}
extension BrokerConnectionResponse: @retroactive Content {}
extension BrokerHoldingResponse: @retroactive Content {}
extension BrokerSyncResponse: @retroactive Content {}
extension BrokerConnectStartRequest: @retroactive Content {}
extension BrokerConnectStartResponse: @retroactive Content {}
extension BrokerSyncStatusResponse: @retroactive Content {}

// MARK: - Statistics

extension StatisticsDTO: @retroactive Content {}
extension ImportedStocksStatisticsDTO: @retroactive Content {}
extension StockStatisticsSummaryDTO: @retroactive Content {}
extension StockAllocationDTO: @retroactive Content {}
extension SectorAllocationDTO: @retroactive Content {}
extension SectorGainItem: @retroactive Content {}
extension SectorGainsResponse: @retroactive Content {}
extension CalendarPerformanceDTO: @retroactive Content {}
extension WatchlistStatisticsDTO: @retroactive Content {}
extension WatchlistSymbolDTO: @retroactive Content {}
extension LooklistStatisticsDTO: @retroactive Content {}
extension LooklistConvictionDTO: @retroactive Content {}
extension MarketStatisticsDTO: @retroactive Content {}
extension MarketHeatmapDTO: @retroactive Content {}

// MARK: - Crypto

extension CryptoAssetResponse: @retroactive Content {}
extension CryptoQuoteResponse: @retroactive Content {}
extension CryptoQuoteShortResponse: @retroactive Content {}
extension CryptoHistoricalLightPoint: @retroactive Content {}
extension CryptoHistoricalFullPoint: @retroactive Content {}
extension CryptoHistoricalPoint: @retroactive Content {}
extension CryptoPortfolioItemRequest: @retroactive Content {}
extension CryptoPortfolioItemResponse: @retroactive Content {}

// MARK: - Expenses

extension BudgetSnapshotRequest: @retroactive Content {}
extension BudgetSnapshotResponse: @retroactive Content {}
extension HouseholdPartnerProfileRequest: @retroactive Content {}
extension HouseholdPartnerProfileResponse: @retroactive Content {}
extension BudgetPlanItemRequest: @retroactive Content {}
extension BudgetPlanItemResponse: @retroactive Content {}
extension FinancialGoalInput: @retroactive Content {}
extension FinancialGoal: @retroactive Content {}
extension GoalPortfolioAllocation: @retroactive Content {}
extension GoalExpenseCategoryLink: @retroactive Content {}
extension GoalContributionInput: @retroactive Content {}
extension GoalContribution: @retroactive Content {}
extension GoalTrajectoryPoint: @retroactive Content {}
extension GoalProgress: @retroactive Content {}
extension GoalOverviewItem: @retroactive Content {}
extension GoalOverview: @retroactive Content {}
extension GoalWhatIfRequest: @retroactive Content {}
extension GoalWhatIfResponse: @retroactive Content {}
extension GoalSuggestion: @retroactive Content {}
extension GoalAdjustmentDraft: @retroactive Content {}
extension GoalTemplate: @retroactive Content {}
extension FinancialGoalBulkUpdate: @retroactive Content {}
extension ExpenseRequest: @retroactive Content {}
extension ExpenseResponse: @retroactive Content {}
extension PillarPlanningSummaryResponse: @retroactive Content {}
extension BudgetMonthSummaryResponse: @retroactive Content {}
extension BudgetYearSummaryResponse: @retroactive Content {}
extension ReportsCashFlowPointResponse: @retroactive Content {}
extension ExpenseCategoryResponse: @retroactive Content {}
extension RecurringTemplateResponse: @retroactive Content {}
extension ReportsOverviewResponse: @retroactive Content {}
extension ReportSuggestionSeverity: @retroactive Content {}
extension ReportSuggestionCategory: @retroactive Content {}
extension ReportSuggestionResponse: @retroactive Content {}
extension ReportSuggestionsResponse: @retroactive Content {}
extension BudgetDriftDashboard: @retroactive Content {}
extension BudgetDisciplineSummary: @retroactive Content {}
extension BudgetAlertPolicy: @retroactive Content {}
extension BudgetReallocationPreviewRequest: @retroactive Content {}
extension BudgetReallocationPreviewResponse: @retroactive Content {}
extension BudgetReallocationCommitRequest: @retroactive Content {}
extension BudgetReallocationEventResponse: @retroactive Content {}
extension BudgetBulkPlanItemUpdateRequest: @retroactive Content {}
extension BudgetTemplateRequest: @retroactive Content {}
extension BudgetTemplateResponse: @retroactive Content {}
extension BudgetTemplateApplyRequest: @retroactive Content {}

// MARK: - Goals & Dashboard Insights

extension GoalRequest: @retroactive Content {}
extension GoalStatus: @retroactive Content {}
extension GoalStatusSource: @retroactive Content {}
extension GoalStatusUpdateRequest: @retroactive Content {}
extension GoalResponse: @retroactive Content {}
extension DashboardInsightsResponse: @retroactive Content {}
extension DashboardFinancialHealthDTO: @retroactive Content {}
extension FinancialHealthStatus: @retroactive Content {}

// MARK: - Activity

extension UserActivityResponse: @retroactive Content {}

// MARK: - Market (FinanceShared types used as Vapor responses)

extension StockDetailsResponse: @retroactive Content {}
extension QuoteResponse: @retroactive Content {}
extension CompanyProfileResponse: @retroactive Content {}
extension PriceBarResponse: @retroactive Content {}
extension HistoryResponse: @retroactive Content {}
extension SearchResultResponse: @retroactive Content {}
extension FxRateResponse: @retroactive Content {}
extension QuoteBatchResponse: @retroactive Content {}
extension BasicFinancialSeriesPoint: @retroactive Content {}
extension BasicFinancialsResponse: @retroactive Content {}
extension RatiosTTMResponse: @retroactive Content {}
extension BalanceSheetStatementResponse: @retroactive Content {}
extension IncomeStatementResponse: @retroactive Content {}
extension CashFlowStatementResponse: @retroactive Content {}
extension FinancialGrowthResponse: @retroactive Content {}
extension AnalystEstimatesResponse: @retroactive Content {}
extension RatiosResponse: @retroactive Content {}
extension ChartBuilderResponse: @retroactive Content {}
extension ChartBuilderMetricCatalogResponse: @retroactive Content {}

// MARK: - AI Insights

extension AIInsightCardResponse: @retroactive Content {}
extension AIInsightHighlight: @retroactive Content {}

// MARK: - Macro / Inflation

extension InflationSnapshotResponse: @retroactive Content {}
extension InflationGaugeDTO: @retroactive Content {}
extension InflationComponentDTO: @retroactive Content {}
extension TopMoverDTO: @retroactive Content {}
extension NextPrintDTO: @retroactive Content {}
extension MacroSeriesPoint: @retroactive Content {}
extension MacroSeriesResponse: @retroactive Content {}
extension SupportedCountry: @retroactive Content {}
extension FedWatchResponse: @retroactive Content {}
extension MacroIndicatorDTO: @retroactive Content {}
extension FOMCMeetingDTO: @retroactive Content {}
extension RateMoveOddsDTO: @retroactive Content {}
extension MacroItemDTO: @retroactive Content {}
extension MacroItemsResponse: @retroactive Content {}
extension MacroItemSeriesResponse: @retroactive Content {}
extension PersonalInflationResponse: @retroactive Content {}
extension PersonalInflationComponentDTO: @retroactive Content {}
extension HousingHubResponse: @retroactive Content {}
extension EconomyHubResponse: @retroactive Content {}
extension PolicyWatchResponse: @retroactive Content {}

// MARK: - Receipts

extension ReceiptParseQRRequest: @retroactive Content {}
extension ReceiptDraftResponse: @retroactive Content {}
extension ReceiptDraft: @retroactive Content {}

// MARK: - Banking

extension BankConnectionResponse: @retroactive Content {}
extension BankAccountResponse: @retroactive Content {}
extension BankTransactionResponse: @retroactive Content {}
extension BankLinkSessionResponse: @retroactive Content {}
extension BankExchangeRequest: @retroactive Content {}
extension BankTransactionImportRequest: @retroactive Content {}
extension BankSyncResponse: @retroactive Content {}
extension BankInstitutionResponse: @retroactive Content {}
extension BankHostedLinkRequest: @retroactive Content {}

// MARK: - Thesis Watch

extension ThesisWatchFeedResponse: @retroactive Content {}
extension ThesisWatchStory: @retroactive Content {}
extension ThesisWatchFeedbackRequest: @retroactive Content {}
extension ThesisWatchNotificationPreferences: @retroactive Content {}
extension UpdateThesisWatchNotificationPreferences: @retroactive Content {}

// MARK: - Spreadsheet import

extension SpreadsheetImportColumn: @retroactive Content {}
extension SpreadsheetImportSheet: @retroactive Content {}
extension SpreadsheetImportCategoryMapping: @retroactive Content {}
extension SpreadsheetImportPreviewRow: @retroactive Content {}
extension SpreadsheetImportPreview: @retroactive Content {}
extension SpreadsheetImportRowOverride: @retroactive Content {}
extension SpreadsheetImportDecisionRequest: @retroactive Content {}
extension SpreadsheetImportAnalysisResponse: @retroactive Content {}
extension SpreadsheetImportPreviewResponse: @retroactive Content {}
extension SpreadsheetImportRowResult: @retroactive Content {}
extension SpreadsheetImportCommitResponse: @retroactive Content {}
