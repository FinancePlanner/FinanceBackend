import Crypto
import Fluent
import Foundation
import StockPlanShared
import Vapor

struct PortfolioManagementController: RouteCollection {
    private struct ComparisonQuery: Content {
        let left: String
        let right: String
    }

    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware())
        let read = protected.grouped(ScopeRequirementMiddleware(.portfolioRead))
        let write = protected.grouped(ScopeRequirementMiddleware(.portfolioWrite))

        read.group("portfolios") { portfolios in
            portfolios.get(use: list)
            portfolios.get("compare", use: compare)
            portfolios.group(":portfolioId") { portfolio in
                portfolio.get(use: get)
                portfolio.get("members", use: members)
                portfolio.get("invitations", use: invitations)
                portfolio.get("cash", use: cashPositions)
                portfolio.get("accounts", use: accounts)
            }
        }

        write.group("portfolios") { portfolios in
            portfolios.post(use: create)
            portfolios.group(":portfolioId") { portfolio in
                portfolio.patch(use: update)
                portfolio.delete(use: delete)
                portfolio.post("archive", use: archive)
                portfolio.post("clone", use: clone)
                portfolio.delete("members", ":membershipId", use: revokeMember)
                portfolio.post("leave", use: leavePortfolio)
                portfolio.post("invitations", use: invite)
                portfolio.delete("invitations", ":invitationId", use: revokeInvitation)
                portfolio.post("cash", use: createCashPosition)
                portfolio.put("cash", ":cashId", use: updateCashPosition)
                portfolio.delete("cash", ":cashId", use: deleteCashPosition)
                portfolio.put("accounts", ":accountId", use: assignAccount)
            }
        }
        write.post("portfolio-invitations", "accept", use: acceptInvitation)
    }

    @Sendable
    func list(req: Request) async throws -> PortfolioPageResponse {
        let session = try req.auth.require(SessionToken.self)
        _ = try await ensureDefaultPortfolioListId(userId: session.userId, on: req.db)

        let owned = try await PortfolioList.query(on: req.db)
            .filter(\.$userId == session.userId)
            .sort(\.$isDefault, .descending)
            .sort(\.$createdAt, .ascending)
            .all()
        let memberships = try await PortfolioMembershipRecord.query(on: req.db)
            .filter(\.$userId == session.userId)
            .filter(\.$status == "active")
            .all()
        let sharedIds = memberships.map(\.portfolioId)
        let shared = sharedIds.isEmpty
            ? []
            : try await PortfolioList.query(on: req.db).filter(\.$id ~~ sharedIds).all()

        var items = [Portfolio]()
        for portfolio in owned + shared where portfolio.archivedAt == nil {
            let context = try await req.portfolioAccessService.require(
                portfolioId: portfolio.requireID(),
                userId: session.userId,
                on: req.db
            )
            items.append(makeResponse(context))
        }
        return PortfolioPageResponse(items: items)
    }

    @Sendable
    func create(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(PortfolioCreateRequest.self)
        try validate(payload)

        let entitlement = try await req.entitlementResolver.resolve(userId: session.userId, on: req.db)
        let count = try await PortfolioList.query(on: req.db)
            .filter(\.$userId == session.userId)
            .filter(\.$archivedAt == nil)
            .count()
        let isBasic = payload.purpose == .personal && payload.ownership == .individual && payload.mode == .actual
        if entitlement.isPro == false, isBasic == false {
            throw BillingUpgradeRequiredError(feature: .advancedPortfolios, plan: entitlement.level)
        }
        let limit = entitlement.isPro ? 25 : 1
        guard count < limit else {
            throw BillingUpgradeRequiredError(
                feature: .portfolioLists,
                plan: entitlement.level,
                limit: limit,
                current: count
            )
        }

        let portfolio = try PortfolioList(
            userId: session.userId,
            name: normalizeListName(payload.name),
            isDefault: count == 0,
            purpose: payload.purpose.rawValue,
            ownership: payload.ownership.rawValue,
            mode: payload.mode.rawValue,
            baseCurrency: normalizeCurrency(payload.baseCurrency),
            sourcePortfolioId: payload.sourcePortfolioId.flatMap(UUID.init(uuidString:)),
            clonedAt: payload.sourcePortfolioId == nil ? nil : Date()
        )
        try await portfolio.save(on: req.db)

        if let sourceId = portfolio.sourcePortfolioId {
            try await copySandbox(
                sourceId: sourceId,
                destination: portfolio,
                userId: session.userId,
                copyRetirementPlan: payload.copyRetirementPlan,
                req: req
            )
        }

        let context = try await req.portfolioAccessService.require(
            portfolioId: portfolio.requireID(),
            userId: session.userId,
            on: req.db
        )
        let response = Response(status: .created)
        try response.content.encode(makeResponse(context))
        return response
    }

    @Sendable
    func get(req: Request) async throws -> Portfolio {
        let session = try req.auth.require(SessionToken.self)
        let context = try await access(req, userId: session.userId)
        return makeResponse(context)
    }

    @Sendable
    func update(req: Request) async throws -> Portfolio {
        let session = try req.auth.require(SessionToken.self)
        let context = try await access(req, userId: session.userId, editing: true, ownerOnly: true)
        let payload = try req.content.decode(PortfolioUpdateRequest.self)
        if let name = payload.name {
            context.portfolio.name = try normalizeListName(name)
        }
        if let purpose = payload.purpose {
            context.portfolio.purpose = purpose.rawValue
        }
        if let ownership = payload.ownership {
            context.portfolio.ownership = ownership.rawValue
        }
        if let currency = payload.baseCurrency {
            context.portfolio.baseCurrency = normalizeCurrency(currency)
        }
        try await context.portfolio.save(on: req.db)
        return makeResponse(context)
    }

    @Sendable
    func archive(req: Request) async throws -> Portfolio {
        let session = try req.auth.require(SessionToken.self)
        let context = try await access(req, userId: session.userId, ownerOnly: true)
        guard context.portfolio.isDefault == false else {
            throw Abort(.badRequest, reason: "The default portfolio cannot be archived.")
        }
        context.portfolio.archivedAt = Date()
        try await context.portfolio.save(on: req.db)
        return makeResponse(context)
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        let context = try await access(req, userId: session.userId, ownerOnly: true)
        guard context.portfolio.isDefault == false else {
            throw Abort(.badRequest, reason: "The default portfolio cannot be deleted.")
        }
        let connectedAccounts = try await Account.query(on: req.db)
            .filter(\.$portfolioId == context.portfolio.requireID())
            .count()
        guard connectedAccounts == 0 else {
            throw Abort(.conflict, reason: "Move connected accounts to another portfolio before deleting this portfolio.")
        }
        try await context.portfolio.delete(on: req.db)
        return .noContent
    }

    @Sendable
    func clone(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let source = try await access(req, userId: session.userId)
        let payload = try req.content.decode(PortfolioCloneRequest.self)
        let request = try PortfolioCreateRequest(
            name: payload.name,
            purpose: source.portfolio.purpose == PortfolioPurpose.retirement.rawValue ? .retirement : .personal,
            ownership: .individual,
            mode: .hypothetical,
            baseCurrency: source.portfolio.baseCurrency,
            sourcePortfolioId: source.portfolio.requireID().uuidString,
            copyRetirementPlan: payload.copyRetirementPlan
        )
        return try await createFromPayload(request, session: session, req: req)
    }

    @Sendable
    func members(req: Request) async throws -> [PortfolioMembership] {
        let session = try req.auth.require(SessionToken.self)
        let context = try await access(req, userId: session.userId)
        let owner = try await User.find(context.portfolio.userId, on: req.db)
        let ownerMembership = try PortfolioMembership(
            id: "owner:\(context.portfolio.userId.uuidString)",
            portfolioId: context.portfolio.requireID().uuidString,
            userId: context.portfolio.userId.uuidString,
            displayName: owner?.username ?? owner?.email ?? "Owner",
            email: owner?.email ?? "",
            role: .owner,
            status: .active,
            joinedAt: formatISODateTime(context.portfolio.createdAt),
            createdAt: formatISODateTime(context.portfolio.createdAt) ?? ""
        )
        let records = try await PortfolioMembershipRecord.query(on: req.db)
            .filter(\.$portfolioId == context.portfolio.requireID())
            .filter(\.$status == "active")
            .all()
        let users = try await User.query(on: req.db).filter(\.$id ~~ records.map(\.userId)).all()
        let usersById = Dictionary(uniqueKeysWithValues: users.compactMap { user in
            user.id.map { ($0, user) }
        })
        return [ownerMembership] + records.compactMap { record in
            guard let id = record.id, let user = usersById[record.userId] else { return nil }
            return PortfolioMembership(
                id: id.uuidString,
                portfolioId: record.portfolioId.uuidString,
                userId: record.userId.uuidString,
                displayName: user.username ?? user.email,
                email: user.email,
                role: PortfolioRole(rawValue: record.role) ?? .editor,
                status: PortfolioMembershipStatus(rawValue: record.status) ?? .active,
                joinedAt: formatISODateTime(record.joinedAt),
                createdAt: formatISODateTime(record.createdAt) ?? ""
            )
        }
    }

    @Sendable
    func invitations(req: Request) async throws -> [PortfolioInvitation] {
        let session = try req.auth.require(SessionToken.self)
        let context = try await access(req, userId: session.userId, ownerOnly: true)
        return try await PortfolioInvitationRecord.query(on: req.db)
            .filter(\.$portfolioId == context.portfolio.requireID())
            .sort(\.$createdAt, .descending)
            .all()
            .compactMap(makeInvitation)
    }

    @Sendable
    func invite(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let context = try await access(req, userId: session.userId, ownerOnly: true)
        guard context.capabilities.canManageMembers else {
            throw BillingUpgradeRequiredError(feature: .jointPortfolios, plan: context.ownerEntitlement.level)
        }
        let payload = try req.content.decode(PortfolioInvitationCreateRequest.self)
        guard payload.role == .editor else {
            throw Abort(.badRequest, reason: "Invitations can only grant editor access.")
        }
        let email = payload.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.contains("@") else { throw Abort(.badRequest, reason: "A valid email is required.") }
        if let invitedUser = try await User.query(on: req.db).filter(\.$email == email).first() {
            guard invitedUser.id != context.portfolio.userId else {
                throw Abort(.conflict, reason: "The portfolio owner is already a member.")
            }
            if let invitedUserId = invitedUser.id,
               try await PortfolioMembershipRecord.query(on: req.db)
               .filter(\.$portfolioId == context.portfolio.requireID())
               .filter(\.$userId == invitedUserId)
               .filter(\.$status == PortfolioMembershipStatus.active.rawValue)
               .first() != nil
            {
                throw Abort(.conflict, reason: "This person is already a portfolio member.")
            }
        }
        if try await PortfolioInvitationRecord.query(on: req.db)
            .filter(\.$portfolioId == context.portfolio.requireID())
            .filter(\.$email == email)
            .filter(\.$status == PortfolioInvitationStatus.pending.rawValue)
            .first() != nil
        {
            throw Abort(.conflict, reason: "An active invitation already exists for this email address.")
        }

        let activeCount = try await PortfolioMembershipRecord.query(on: req.db)
            .filter(\.$portfolioId == context.portfolio.requireID())
            .filter(\.$status == "active")
            .count()
        let pendingCount = try await PortfolioInvitationRecord.query(on: req.db)
            .filter(\.$portfolioId == context.portfolio.requireID())
            .filter(\.$status == "pending")
            .count()
        guard activeCount + pendingCount < 5 else {
            throw Abort(.conflict, reason: "A joint portfolio supports at most five editors.")
        }

        let token = [UUID().uuidString, UUID().uuidString].joined(separator: ".")
        let record = try PortfolioInvitationRecord(
            portfolioId: context.portfolio.requireID(),
            email: email,
            tokenHash: sha256(token),
            expiresAt: Date().addingTimeInterval(7 * 86400)
        )
        try await record.save(on: req.db)
        context.portfolio.ownership = PortfolioOwnership.joint.rawValue
        try await context.portfolio.save(on: req.db)
        try await req.application.mailer.send(
            MailMessage(
                to: email,
                subject: "You were invited to a Norviq portfolio",
                body: "Open Norviq and accept this invitation token: \(token)",
                purpose: "portfolio_invitation",
                challengeId: record.id
            ),
            on: req
        )
        let response = Response(status: .created)
        try response.content.encode(makeInvitation(record) ?? abortMissingID())
        return response
    }

    @Sendable
    func acceptInvitation(req: Request) async throws -> PortfolioMembership {
        let session = try req.auth.require(SessionToken.self)
        let payload = try req.content.decode(PortfolioInvitationAcceptRequest.self)
        guard let record = try await PortfolioInvitationRecord.query(on: req.db)
            .filter(\.$tokenHash == sha256(payload.token))
            .filter(\.$status == "pending")
            .first()
        else {
            throw Abort(.notFound, reason: "Invitation not found.")
        }
        guard record.expiresAt > Date() else {
            record.status = "expired"
            try await record.save(on: req.db)
            throw Abort(.gone, reason: "Invitation expired.")
        }
        guard let user = try await User.find(session.userId, on: req.db),
              user.isVerified,
              user.email.lowercased() == record.email.lowercased()
        else {
            throw Abort(.forbidden, reason: "Use the verified account that received this invitation.")
        }

        let membership = try await PortfolioMembershipRecord.query(on: req.db)
            .filter(\.$portfolioId == record.portfolioId)
            .filter(\.$userId == session.userId)
            .first() ?? PortfolioMembershipRecord(portfolioId: record.portfolioId, userId: session.userId)
        membership.role = "editor"
        membership.status = "active"
        membership.joinedAt = Date()
        try await membership.save(on: req.db)
        record.status = "accepted"
        record.acceptedAt = Date()
        try await record.save(on: req.db)
        return try PortfolioMembership(
            id: membership.requireID().uuidString,
            portfolioId: record.portfolioId.uuidString,
            userId: session.userId.uuidString,
            displayName: user.username ?? user.email,
            email: user.email,
            role: .editor,
            status: .active,
            joinedAt: formatISODateTime(membership.joinedAt),
            createdAt: formatISODateTime(membership.createdAt) ?? ""
        )
    }

    @Sendable
    func revokeInvitation(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        let context = try await access(req, userId: session.userId, ownerOnly: true)
        let invitationId = try parameter(req, "invitationId")
        guard let record = try await PortfolioInvitationRecord.query(on: req.db)
            .filter(\.$id == invitationId)
            .filter(\.$portfolioId == context.portfolio.requireID())
            .first()
        else { throw Abort(.notFound, reason: "Invitation not found.") }
        record.status = "revoked"
        try await record.save(on: req.db)
        try await collapseJointOwnershipIfEmpty(context.portfolio, on: req.db)
        return .noContent
    }

    @Sendable
    func revokeMember(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        let context = try await access(req, userId: session.userId, ownerOnly: true)
        let membershipId = try parameter(req, "membershipId")
        guard let membership = try await PortfolioMembershipRecord.query(on: req.db)
            .filter(\.$id == membershipId)
            .filter(\.$portfolioId == context.portfolio.requireID())
            .filter(\.$status == PortfolioMembershipStatus.active.rawValue)
            .first()
        else { throw Abort(.notFound, reason: "Portfolio member not found.") }
        membership.status = PortfolioMembershipStatus.revoked.rawValue
        try await membership.save(on: req.db)
        try await collapseJointOwnershipIfEmpty(context.portfolio, on: req.db)
        return .noContent
    }

    @Sendable
    func leavePortfolio(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        let context = try await access(req, userId: session.userId)
        guard context.role == .editor else {
            throw Abort(.badRequest, reason: "A portfolio owner cannot leave their own portfolio.")
        }
        guard let membership = try await PortfolioMembershipRecord.query(on: req.db)
            .filter(\.$portfolioId == context.portfolio.requireID())
            .filter(\.$userId == session.userId)
            .filter(\.$status == PortfolioMembershipStatus.active.rawValue)
            .first()
        else { throw Abort(.notFound, reason: "Portfolio membership not found.") }
        membership.status = PortfolioMembershipStatus.left.rawValue
        try await membership.save(on: req.db)
        try await collapseJointOwnershipIfEmpty(context.portfolio, on: req.db)
        return .noContent
    }

    @Sendable
    func cashPositions(req: Request) async throws -> [PortfolioCashPosition] {
        let session = try req.auth.require(SessionToken.self)
        let context = try await access(req, userId: session.userId)
        return try await PortfolioCashPositionRecord.query(on: req.db)
            .filter(\.$portfolioId == context.portfolio.requireID())
            .sort(\.$asOf, .descending)
            .all()
            .compactMap(makeCashPosition)
    }

    @Sendable
    func createCashPosition(req: Request) async throws -> Response {
        let session = try req.auth.require(SessionToken.self)
        let context = try await access(req, userId: session.userId, editing: true)
        let payload = try req.content.decode(PortfolioCashPositionRequest.self)
        let record = try PortfolioCashPositionRecord(
            portfolioId: context.portfolio.requireID(),
            label: normalizeListName(payload.label, field: "label"),
            currency: normalizeCurrency(payload.currency),
            balance: payload.balance,
            asOf: parseDate(payload.asOf)
        )
        try await record.save(on: req.db)
        let response = Response(status: .created)
        try response.content.encode(makeCashPosition(record) ?? abortMissingID())
        return response
    }

    @Sendable
    func updateCashPosition(req: Request) async throws -> PortfolioCashPosition {
        let session = try req.auth.require(SessionToken.self)
        let context = try await access(req, userId: session.userId, editing: true)
        let cashId = try parameter(req, "cashId")
        let payload = try req.content.decode(PortfolioCashPositionRequest.self)
        guard let record = try await PortfolioCashPositionRecord.query(on: req.db)
            .filter(\.$id == cashId)
            .filter(\.$portfolioId == context.portfolio.requireID())
            .first()
        else { throw Abort(.notFound, reason: "Cash position not found.") }
        record.label = try normalizeListName(payload.label, field: "label")
        record.currency = normalizeCurrency(payload.currency)
        record.balance = payload.balance
        record.asOf = try parseDate(payload.asOf)
        try await record.save(on: req.db)
        return try makeCashPosition(record) ?? abortMissingID()
    }

    @Sendable
    func deleteCashPosition(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        let context = try await access(req, userId: session.userId, editing: true)
        let cashId = try parameter(req, "cashId")
        guard let record = try await PortfolioCashPositionRecord.query(on: req.db)
            .filter(\.$id == cashId)
            .filter(\.$portfolioId == context.portfolio.requireID())
            .first()
        else { throw Abort(.notFound, reason: "Cash position not found.") }
        try await record.delete(on: req.db)
        return .noContent
    }

    @Sendable
    func accounts(req: Request) async throws -> [Account] {
        let session = try req.auth.require(SessionToken.self)
        let context = try await access(req, userId: session.userId)
        return try await Account.query(on: req.db)
            .filter(\.$portfolioId == context.portfolio.requireID())
            .all()
    }

    @Sendable
    func assignAccount(req: Request) async throws -> HTTPStatus {
        let session = try req.auth.require(SessionToken.self)
        let context = try await access(req, userId: session.userId, editing: true, ownerOnly: true)
        guard context.portfolio.mode == PortfolioMode.actual.rawValue else {
            throw Abort(.badRequest, reason: "Connected accounts can only belong to actual portfolios.")
        }
        let accountId = try parameter(req, "accountId")
        guard let account = try await Account.query(on: req.db)
            .filter(\.$id == accountId)
            .filter(\.$userId == session.userId)
            .first()
        else { throw Abort(.notFound, reason: "Account not found.") }
        account.portfolioId = try context.portfolio.requireID()
        try await account.save(on: req.db)
        return .noContent
    }

    @Sendable
    func compare(req: Request) async throws -> PortfolioComparison {
        let session = try req.auth.require(SessionToken.self)
        let query = try req.query.decode(ComparisonQuery.self)
        guard let leftId = UUID(uuidString: query.left), let rightId = UUID(uuidString: query.right) else {
            throw Abort(.badRequest, reason: "left and right must be portfolio IDs.")
        }
        let left = try await req.portfolioAccessService.require(portfolioId: leftId, userId: session.userId, on: req.db)
        let right = try await req.portfolioAccessService.require(portfolioId: rightId, userId: session.userId, on: req.db)
        let leftStocks = try await Stock.query(on: req.db).filter(\.$portfolioListId == leftId).all()
        let rightStocks = try await Stock.query(on: req.db).filter(\.$portfolioListId == rightId).all()
        return makeComparison(left: left, leftStocks: leftStocks, right: right, rightStocks: rightStocks)
    }

    private func createFromPayload(
        _ payload: PortfolioCreateRequest,
        session: SessionToken,
        req: Request
    ) async throws -> Response {
        let entitlement = try await req.entitlementResolver.resolve(userId: session.userId, on: req.db)
        guard entitlement.isPro else {
            throw BillingUpgradeRequiredError(feature: .advancedPortfolios, plan: entitlement.level)
        }
        let count = try await PortfolioList.query(on: req.db)
            .filter(\.$userId == session.userId)
            .filter(\.$archivedAt == nil)
            .count()
        guard count < 25 else {
            throw BillingUpgradeRequiredError(feature: .portfolioLists, plan: entitlement.level, limit: 25, current: count)
        }
        let destination = try PortfolioList(
            userId: session.userId,
            name: normalizeListName(payload.name),
            purpose: payload.purpose.rawValue,
            ownership: payload.ownership.rawValue,
            mode: payload.mode.rawValue,
            baseCurrency: normalizeCurrency(payload.baseCurrency),
            sourcePortfolioId: payload.sourcePortfolioId.flatMap(UUID.init(uuidString:)),
            clonedAt: Date()
        )
        try await destination.save(on: req.db)
        if let sourceId = destination.sourcePortfolioId {
            try await copySandbox(
                sourceId: sourceId,
                destination: destination,
                userId: session.userId,
                copyRetirementPlan: payload.copyRetirementPlan,
                req: req
            )
        }
        let context = try await req.portfolioAccessService.require(
            portfolioId: destination.requireID(),
            userId: session.userId,
            on: req.db
        )
        let response = Response(status: .created)
        try response.content.encode(makeResponse(context))
        return response
    }

    private func copySandbox(
        sourceId: UUID,
        destination: PortfolioList,
        userId: UUID,
        copyRetirementPlan: Bool,
        req: Request
    ) async throws {
        _ = try await req.portfolioAccessService.require(portfolioId: sourceId, userId: userId, on: req.db)
        guard destination.mode == PortfolioMode.hypothetical.rawValue else {
            throw Abort(.badRequest, reason: "Only hypothetical portfolios can clone holdings.")
        }
        let destinationId = try destination.requireID()
        for stock in try await Stock.query(on: req.db).filter(\.$portfolioListId == sourceId).all() {
            let copy = Stock(
                userId: userId,
                portfolioListId: destinationId,
                symbol: stock.symbol,
                shares: stock.shares,
                buyPrice: stock.buyPrice,
                buyDate: stock.buyDate,
                notes: stock.notes,
                category: stock.category,
                sourceProvider: "portfolio_clone"
            )
            try await copy.save(on: req.db)
        }
        for cash in try await PortfolioCashPositionRecord.query(on: req.db).filter(\.$portfolioId == sourceId).all() {
            try await PortfolioCashPositionRecord(
                portfolioId: destinationId,
                label: cash.label,
                currency: cash.currency,
                balance: cash.balance,
                asOf: cash.asOf
            ).save(on: req.db)
        }
        if copyRetirementPlan,
           let plan = try await RetirementPlanRecord.query(on: req.db).filter(\.$portfolioId == sourceId).first()
        {
            try await RetirementPlanRecord(
                portfolioId: destinationId,
                ruleVersion: plan.ruleVersion,
                inputJSON: plan.inputJSON
            ).save(on: req.db)
        }
    }

    private func access(
        _ req: Request,
        userId: UUID,
        editing: Bool = false,
        ownerOnly: Bool = false
    ) async throws -> PortfolioAccessContext {
        try await req.portfolioAccessService.require(
            portfolioId: parameter(req, "portfolioId"),
            userId: userId,
            editing: editing,
            ownerOnly: ownerOnly,
            on: req.db
        )
    }

    private func collapseJointOwnershipIfEmpty(
        _ portfolio: PortfolioList,
        on database: any Database
    ) async throws {
        let portfolioId = try portfolio.requireID()
        let active = try await PortfolioMembershipRecord.query(on: database)
            .filter(\.$portfolioId == portfolioId)
            .filter(\.$status == PortfolioMembershipStatus.active.rawValue)
            .count()
        let pending = try await PortfolioInvitationRecord.query(on: database)
            .filter(\.$portfolioId == portfolioId)
            .filter(\.$status == PortfolioInvitationStatus.pending.rawValue)
            .count()
        if active == 0, pending == 0 {
            portfolio.ownership = PortfolioOwnership.individual.rawValue
            try await portfolio.save(on: database)
        }
    }

    private func makeResponse(_ context: PortfolioAccessContext) -> Portfolio {
        let record = context.portfolio
        return Portfolio(
            id: (record.id ?? UUID()).uuidString,
            ownerUserId: record.userId.uuidString,
            name: record.name,
            purpose: PortfolioPurpose(rawValue: record.purpose) ?? .personal,
            ownership: PortfolioOwnership(rawValue: record.ownership) ?? .individual,
            mode: PortfolioMode(rawValue: record.mode) ?? .actual,
            baseCurrency: record.baseCurrency,
            isDefault: record.isDefault,
            sourcePortfolioId: record.sourcePortfolioId?.uuidString,
            clonedAt: formatISODateTime(record.clonedAt),
            archivedAt: formatISODateTime(record.archivedAt),
            currentUserRole: context.role,
            capabilities: context.capabilities,
            createdAt: formatISODateTime(record.createdAt) ?? "",
            updatedAt: formatISODateTime(record.updatedAt)
        )
    }

    private func makeInvitation(_ record: PortfolioInvitationRecord) -> PortfolioInvitation? {
        guard let id = record.id else { return nil }
        return PortfolioInvitation(
            id: id.uuidString,
            portfolioId: record.portfolioId.uuidString,
            email: record.email,
            role: PortfolioRole(rawValue: record.role) ?? .editor,
            status: PortfolioInvitationStatus(rawValue: record.status) ?? .pending,
            expiresAt: formatISODateTime(record.expiresAt) ?? "",
            acceptedAt: formatISODateTime(record.acceptedAt),
            createdAt: formatISODateTime(record.createdAt) ?? ""
        )
    }

    private func makeCashPosition(_ record: PortfolioCashPositionRecord) -> PortfolioCashPosition? {
        guard let id = record.id else { return nil }
        return PortfolioCashPosition(
            id: id.uuidString,
            portfolioId: record.portfolioId.uuidString,
            label: record.label,
            currency: record.currency,
            balance: record.balance,
            asOf: formatISODateTime(record.asOf) ?? "",
            createdAt: formatISODateTime(record.createdAt) ?? "",
            updatedAt: formatISODateTime(record.updatedAt)
        )
    }

    private func makeComparison(
        left: PortfolioAccessContext,
        leftStocks: [Stock],
        right: PortfolioAccessContext,
        rightStocks: [Stock]
    ) -> PortfolioComparison {
        let leftValues = Dictionary(grouping: leftStocks, by: { $0.symbol.uppercased() })
            .mapValues { $0.reduce(0) { $0 + ($1.shares * $1.buyPrice) } }
        let rightValues = Dictionary(grouping: rightStocks, by: { $0.symbol.uppercased() })
            .mapValues { $0.reduce(0) { $0 + ($1.shares * $1.buyPrice) } }
        let leftTotal = leftValues.values.reduce(0, +)
        let rightTotal = rightValues.values.reduce(0, +)
        let symbols = Set(leftValues.keys).union(rightValues.keys).sorted()
        let holdings = symbols.map { symbol in
            let leftValue = leftValues[symbol] ?? 0
            let rightValue = rightValues[symbol] ?? 0
            let leftWeight = leftTotal > 0 ? leftValue / leftTotal * 100 : 0
            let rightWeight = rightTotal > 0 ? rightValue / rightTotal * 100 : 0
            return PortfolioComparisonHolding(
                symbol: symbol,
                leftValue: leftValue,
                rightValue: rightValue,
                leftWeightPercent: leftWeight,
                rightWeightPercent: rightWeight,
                valueDifference: rightValue - leftValue,
                weightDifferencePercent: rightWeight - leftWeight
            )
        }
        return PortfolioComparison(
            left: PortfolioComparisonColumn(
                portfolioId: (left.portfolio.id ?? UUID()).uuidString,
                name: left.portfolio.name,
                baseCurrency: left.portfolio.baseCurrency,
                totalValue: leftTotal,
                cashBalance: 0,
                holdingCount: leftStocks.count
            ),
            right: PortfolioComparisonColumn(
                portfolioId: (right.portfolio.id ?? UUID()).uuidString,
                name: right.portfolio.name,
                baseCurrency: right.portfolio.baseCurrency,
                totalValue: rightTotal,
                cashBalance: 0,
                holdingCount: rightStocks.count
            ),
            holdings: holdings,
            generatedAt: formatISODateTime(Date()) ?? ""
        )
    }

    private func validate(_ payload: PortfolioCreateRequest) throws {
        if payload.sourcePortfolioId != nil, payload.mode != .hypothetical {
            throw Abort(.badRequest, reason: "Clones must use hypothetical mode.")
        }
        if payload.mode == .hypothetical, payload.ownership == .joint {
            throw Abort(.badRequest, reason: "Hypothetical portfolios cannot be joint.")
        }
    }

    private func parameter(_ req: Request, _ name: String) throws -> UUID {
        guard let raw = req.parameters.get(name), let id = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "Invalid \(name).")
        }
        return id
    }

    private func normalizeCurrency(_ raw: String) -> String {
        String(raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().prefix(3))
    }

    private func parseDate(_ raw: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        if let value = formatter.date(from: raw) {
            return value
        }
        formatter.formatOptions = [.withFullDate]
        guard let value = formatter.date(from: raw) else {
            throw Abort(.badRequest, reason: "Invalid date.")
        }
        return value
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func abortMissingID<T>() throws -> T {
        throw Abort(.internalServerError, reason: "Record ID was not generated.")
    }
}
