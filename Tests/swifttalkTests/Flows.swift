
import XCTest
import NIOHTTP1
import PostgreSQL
@testable import SwiftTalkServerLib

struct QueryAndResult {
    let query: Query<Any>
    let response: Any
    init<A>(query: Query<A>, response: A) {
        self.query = query.map { $0 }
        self.response = response
    }
    
    init(_ query: Query<()>) {
        self.query = query.map { $0 }
        self.response = ()
    }
}

extension QueryAndResult: Equatable {
    static func ==(l: QueryAndResult, r: QueryAndResult) -> Bool {
        return l.query.query == r.query.query
    }
}

struct TestEnv {
    let requestEnvironment: RequestEnvironment
    let connection: TestConnection?
    let file: StaticString
    let line: UInt
}

extension TestEnv: ContainsRequestEnvironment {}
extension TestEnv: ContainsSession {
    var session: Session? { return requestEnvironment.session }
}

extension TestEnv: CanQuery {
    func execute<A>(_ query: Query<A>) -> Either<A, Error> {
        guard let c = connection else { XCTFail(); return .right(TestErr()) }
        do {
            return .left(try c.execute(query))
        } catch {
            return .right(error)
        }
    }
    
    func getConnection() -> Either<ConnectionProtocol, Error> {
        fatalError("not implemented yet")
    }
    
    
}

struct Flow {
    let session: Session?
    let currentPage: TestInterpreter

    private static func run(_ session: Session?, _ route: Route, connection: TestConnection? = nil, assertQueriesDone: Bool = true, _ file: StaticString, _ line: UInt) throws -> TestInterpreter {
        let env = RequestEnvironment(route: route, hashedAssetName: { $0 }, buildSession: { session }, connection: noConnection, resourcePaths: [])
        let testEnv = TestEnv(requestEnvironment: env, connection: connection, file: file, line: line)
        let t: Reader<TestEnv, TestInterpreter> = try route.interpret()
        let result = t.run(testEnv)
        if let c = connection, assertQueriesDone { c.assertDone() }
        return result
    }
    
    static func landingPage(session: Session?, file: StaticString = #file, line: UInt = #line, _ route: Route) throws -> Flow {
        return try Flow(session: session, currentPage: run(session, route, file, line))
    }
    
    func verify(cond: (TestInterpreter) -> ()) {
        cond(currentPage)
    }
    
    func click(_ route: Route, file: StaticString = #file, line: UInt = #line, _ cont: (Flow) throws -> ()) throws {
        testLinksTo(currentPage, route: route)
        try cont(Flow(session: session, currentPage: Flow.run(session, route, file, line)))
    }
    
    func followRedirect(to action: Route, expectedQueries: [QueryAndResult] = [], file: StaticString = #file, line: UInt = #line,  _ then: (Flow) throws -> ()) throws -> () {
        guard case let TestInterpreter._redirect(path: path, headers: _) = currentPage else {
            XCTFail("Expected redirect"); return
        }
        guard action.path == path else {
            XCTFail("Expected \(action), got \(path)"); return
        }
        
        try then(Flow(session: session, currentPage: Flow.run(session, action, connection: TestConnection(expectedQueries), file, line)))
    }
    
    func fillForm(to action: Route, data: [String:String] = [:], expectedQueries: [QueryAndResult] = [], file: StaticString = #file, line: UInt = #line,  _ then: (Flow) throws -> ()) throws {
        guard let f = currentPage.forms().first(where: { $0.action == action }) else {
            XCTFail("Couldn't find a form with action \(action)", file: file, line: line)
            return
        }
        var postData = Dictionary(f.inputs, uniquingKeysWith: { $1 })
        for (key,_) in data {
            XCTAssert(postData[key] != nil)
        }
        let conn = TestConnection(expectedQueries)
        guard case let ._withPostData(cont) = try Flow.run(session, action, connection: conn, assertQueriesDone: false, file, line) else {
            XCTFail("Expected post handler", file: file, line: line)
            return
        }
        let theData = postData.merging(data, uniquingKeysWith: { $1 }).map { (key, value) in "\(key)=\(value.escapeForAttributeValue)"}.joined(separator: "&").data(using: .utf8)!
        let nextPage = cont(theData)
        conn.assertDone()
        try then(Flow(session: session, currentPage: nextPage))
    }
    
    func withSession(_ session: Session?, _ then: (Flow) throws -> ()) throws {
        return try then(Flow(session: session, currentPage: currentPage))
    }
}

final class FlowTests: XCTestCase {
    
    override static func setUp() {
        pushTestEnv()
        let testDate = Date()
        pushGlobals(Globals(currentDate: { testDate }))
    }
    
    func run(_ route: Route) -> (Session?) throws -> TestInterpreter {
        return { (session: Session?) in
            let env = RequestEnvironment(route: route, hashedAssetName: { $0 }, buildSession: { session }, connection: noConnection, resourcePaths: [])
            let i: Reader<RequestEnvironment, TestInterpreter> = try route.interpret()
            return i.run(env)
        }
    }
    
    func testSubscription() throws {
        // todo test coupon codes
        testPlans = plans
        
        let subscribeWithoutASession = try Flow.landingPage(session: nil, .signup(.subscribe))
        subscribeWithoutASession.verify { page in
            testLinksTo(page, route: .login(.login(continue: .subscription(.new(couponCode: nil, team: false)))))
        }
        
        let notSubscribed = try Flow.landingPage(session: nonSubscribedUser, .signup(.subscribe))
        try notSubscribed.click(.subscription(.new(couponCode: nil, team: false)), {
            var confirmedSess = $0.session!
            confirmedSess.user.data.confirmedNameAndEmail = true
            try $0.fillForm(to: .account(.register(couponCode: nil, team: false)), expectedQueries: [
                QueryAndResult(query: confirmedSess.user.update(), response: ())
            ], {
                try $0.withSession(confirmedSess) {
                    try $0.followRedirect(to: .subscription(.new(couponCode: nil, team: false)), expectedQueries: [
                        QueryAndResult(Task.unfinishedSubscriptionReminder(userId: confirmedSess.user.id).schedule(weeks: 1)),
                        QueryAndResult(confirmedSess.user.update())
                    ], {
                        print($0.currentPage)
                    })
                }
            })
        })
    }

    func testTeamSubscription() throws {
        testPlans = plans
        let subscribeWithoutASession = try Flow.landingPage(session: nil, .signup(.subscribeTeam))
        subscribeWithoutASession.verify { page in
            testLinksTo(page, route: .login(.login(continue: .subscription(.new(couponCode: nil, team: true)))))
        }

        let notSubscribed = try Flow.landingPage(session: nonSubscribedUser, .signup(.subscribeTeam))
        try notSubscribed.click(.subscription(.new(couponCode: nil, team: true)), {
            var confirmedSess = $0.session!
            confirmedSess.user.data.confirmedNameAndEmail = true
            confirmedSess.user.data.role = .teamManager
            try $0.fillForm(to: .account(.register(couponCode: nil, team: true)), expectedQueries: [
                QueryAndResult(query: confirmedSess.user.update(), response: ())
            ], {
                try $0.withSession(confirmedSess) {
                    try $0.followRedirect(to: .subscription(.new(couponCode: nil, team: true)), expectedQueries: [
                        QueryAndResult(Task.unfinishedSubscriptionReminder(userId: confirmedSess.user.id).schedule(weeks: 1)),
                        QueryAndResult(confirmedSess.user.update())
                    ], {
                        print($0.currentPage)
                    })
                }
            })
        })
    }

    func testNewSubscription() throws {
        testPlans = plans
        
        // todo test coupon codes
        let i = run(.subscription(.new(couponCode: nil, team: false)))
        // Not logged in
        try i(nil).testIsError()
        
        let form = try TestUnwrap(i(nonSubscribedUser).forms().first)
        XCTAssertEqual(form.action, .account(.register(couponCode: nil, team: false)))
        
        try print(i(subscribedUser))
    }
    
    // IDEA we can have a "click" test that verifies a route is present in the current page, and then proceeds to test that link. this could build up a tree structure of tests (for different combinations). we could branch out if there are multiple choices on a page.
    
    
//    func testRoutes() throws {
//        let r = try routesReachable(startingFrom: .subscribe, session: nil)
//        print(r)
//    }
    
    //    func routesReachable(startingFrom: Route, session: Session?) throws -> [Route] {
    //        var routesChecked: [Route] = []
    //
    //        func helper(queue: inout [Route]) throws {
    //            while let r = queue.popLast() {
    //                guard !routesChecked.contains(r) else { continue }
    //                routesChecked.append(r)
    //                let rendered: TestInterpreter
    //                switch r {
    //                case .home: fatalError()
    //                case .subscribe:
    //
    //                default: fatalError("\(r)")
    //                }
    //                queue.append(contentsOf: rendered.linkTargets())
    //            }
    //        }
    //        var queue = [startingFrom]
    //        try helper(queue: &queue)
    //        return routesChecked
    //    }


    static var allTests = [
        ("testSubscription", testSubscription),
        ("testNewSubscription", testNewSubscription),
    ]
}
