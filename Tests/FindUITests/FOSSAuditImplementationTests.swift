@testable import SearchBackend
import Foundation
import Testing
import SearchCore
@testable import FindUI

private func fossRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("findui-foss-tests-\(UUID())")
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    return root
}
private func fossRequest(_ root: URL, _ query: String = "needle", mode: SearchMode = .contents) -> SearchRequest {
    SearchRequest(query:query,mode:mode,scope:root,includeHidden:false,caseSensitive:false,syntax:.literal,exactNameMatch:false,maxResults:.max)
}

@Test func wordCoverageSurvivesAliasesAndDetectsChangesWithoutHits() async throws {
    let root = try fossRoot(); defer { try? FileManager.default.removeItem(at:root) }
    let cache = root.appendingPathComponent("cache")
    let old = ProcessInfo.processInfo.environment["FINDUI_CACHE_DIRECTORY"]
    setenv("FINDUI_CACHE_DIRECTORY",cache.path,1)
    defer { if let old { setenv("FINDUI_CACHE_DIRECTORY",old,1) } else { unsetenv("FINDUI_CACHE_DIRECTORY") } }
    let real = root.appendingPathComponent("real"), alias = root.appendingPathComponent("alias")
    try FileManager.default.createDirectory(at:real,withIntermediateDirectories:true)
    try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:real)
    let file = real.appendingPathComponent("source.txt")
    try Data("needle before".utf8).write(to:file)
    var preparation = fossRequest(alias); preparation.buildWordIndex = true
    func prepare(_ request: SearchRequest) async throws {
        let result = try await ProcessRunner.run(spec:SearchPipelineCompiler(tools:.resolve()).compile(request).spec,pathOverride:Toolchain.resolve().searchPath)
        #expect(result.exitCode == 0,"\(result.stderr)")
    }
    try await prepare(preparation)
    var request = fossRequest(real); request.refinements.wordSearch = true
    #expect(try await SearchService().search(request:request).results.map(\.path) == [file.path])
    #expect(try await WordIndexService.status(request).state == "updated")
    request.scope = alias
    #expect(try await SearchService().search(request:request).results.map(\.path) == [alias.appendingPathComponent("source.txt").path])
    try Data("replacement".utf8).write(to:file)
    request.query = "replacement"
    let changed = try await SearchService().search(request:request)
    #expect(changed.results.isEmpty && changed.warning?.contains("Update the word index") == true)
    #expect(try await WordIndexService.status(request).changedSources == 1)
    try await prepare(preparation)
    #expect(try await SearchService().search(request:request).results.count == 1)
    try FileManager.default.removeItem(at:file)
    try await prepare(preparation)
    #expect(try await WordIndexService.status(request).sources == 0)
    try Data("newtoken".utf8).write(to:real.appendingPathComponent("added.txt"))
    request.query = "newtoken"
    #expect(try await WordIndexService.status(request).state == "needsUpdate")
    let elsewhere = root.appendingPathComponent("elsewhere")
    try FileManager.default.createDirectory(at:elsewhere,withIntermediateDirectories:true)
    try FileManager.default.removeItem(at:alias)
    try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:elsewhere)
    #expect(try await SearchService().search(request:request).results.isEmpty)
    #expect(try await WordIndexService.status(request).state != "updated")
}

@Test func resultsReuseSortsAndNavigateBeyondAPageWithoutLosingDocuments() async throws {
    let root = try fossRoot(); defer { try? FileManager.default.removeItem(at:root) }
    let store = try ResultStore()
    let file = root.appendingPathComponent("source.txt")
    let rows = (1...1200).map { SearchResult(url:file,kind:.contentMatch,lineNumber:$0,snippet:"needle",tags:["Work"],matchRank:0,sourceOrder:$0) }
    try await store.append(rows)
    let sort = [ResultSort(column:"name",descending:false)]
    let first = try await store.page(0,sort:sort), second = try await store.page(1,sort:sort)
    #expect(first.count == 1000 && second.count == 200)
    #expect(await store.sortBuildCount == 1)
    let totals = try await store.totals(for:first)
    #expect(totals.files == 1 && totals.matches == 1200 && totals.documentCounts[file.path] == 1200)
    let next = try #require(await store.adjacentMatch(to:first.last!,offset:1,sort:sort))
    #expect(next.page == 1 && next.result.id == second.first!.id)
    #expect(try await store.documentPosition(next.result) == 1000)
    let previous = try #require(await store.adjacentMatch(to:next.result,offset:-1,sort:sort))
    #expect(previous.page == 0 && previous.result.id == first.last!.id)
    let facets = try await store.facets()
    #expect(facets.contains { $0.kind == .fileType && $0.value == "txt" && $0.count == 1 })
    #expect(facets.contains { $0.kind == .tag && $0.value == "Work" && $0.count == 1 })
    let export = root.appendingPathComponent("out.csv")
    #expect(try await store.exportCSV(to:export,sort:sort) == 1200)
    #expect(await store.sortBuildCount == 1)
    #expect(try String(contentsOf:export,encoding:.utf8).contains("1200"))
    let extra = SearchResult(url:root.appendingPathComponent("a.txt"),kind:.file,matchRank:0,sourceOrder:1201)
    try await store.append([extra])
    #expect(try await store.page(0,sort:sort).first?.id == extra.id)
    #expect(await store.sortBuildCount == 1)
    // Embedded NULs separate archive members and record keys. SQL must retain
    // the whole identity, rather than merging every member of one archive.
    let members = try ResultStore()
    for i in 0..<2 {
        try await members.append([SearchResult(url:file,kind:.contentMatch,extractedOrigin:.init(extractor:"test",line:1,page:nil,members:[.init(name:"same.txt",index:UInt64(i))]),snippet:"needle",matchRank:0,sourceOrder:i)])
    }
    let memberRows = try await members.page(0)
    #expect(try await members.totals(for:memberRows).documents == 2)
}

@Test func snapshotCandidatesMatchScanForBooleanAndUnicodeFallbacks() async throws {
    let root = try fossRoot(); defer { try? FileManager.default.removeItem(at:root) }
    let scope = root.appendingPathComponent("files")
    try FileManager.default.createDirectory(at:scope,withIntermediateDirectories:true)
    for name in ["Needle.txt","a needle.md","other.txt","résumé.txt","cafe\u{301}.txt","quote\"name.txt","[x].txt"] { try Data().write(to:scope.appendingPathComponent(name)) }
    let service = IndexService(), build = try await service.buildIndex(name:"Names",scope:scope,includeHidden:true)
    let db = root.appendingPathComponent("names.sqlite")
    try IndexArtifact(metadata:build.metadata,entries:build.entries).save(db)
    let worker = try #require(Toolchain.resolve().contentWorker)
    var source = QuerySource(); source.kind = .snapshot; source.path = db.path
    let records = root.appendingPathComponent("frozen.records")
    let dumped = try await ProcessRunner.run(spec: CommandSpec(executable: worker, arguments: ["--snapshot-records", db.path]), pathOverride: Toolchain.resolve().searchPath)
    #expect(dumped.exitCode == 0)
    try Data(dumped.stdout.utf8).write(to: records)
    var scanSource = source; scanSource.path = records.path; scanSource.records = true
    for value in ["needle","Needle","é","café","[x]","quote\"","e","not-present"] {
        for sensitive in [true,false] {
            var request = fossRequest(scope,"",mode:.files); request.useIndex = true; request.includeHidden = true
            request.refinements.name = value; request.refinements.fileCaseSensitive = sensitive
            let pipeline = try SearchPipelineCompiler(tools:.resolve()).compile(request,source:source)
            let optimized = try await ProcessRunner.run(spec:pipeline.spec,pathOverride:Toolchain.resolve().searchPath)
            let scan = try await ProcessRunner.run(spec:SearchPipelineCompiler(tools:.resolve()).compile(request,source:scanSource).spec,pathOverride:Toolchain.resolve().searchPath)
            #expect(optimized.exitCode == 0 && scan.exitCode == 0,"\(optimized.stderr)")
            #expect(optimized.stdout.split(separator: "\0").sorted() == scan.stdout.split(separator: "\0").sorted(),"\(value), case \(sensitive)")
        }
    }
    for files in [SearchRuleTree<SearchFileRule>.rule(.name("(needle|other).*\\.(txt|md)$",.regex)),
                  .rule(.name("(?i)needle.*",.regex)), .rule(.name("*needle*",.glob)),
                  .rule(.name("(needle)?|other",.regex)), .rule(.name("(?=Needle)Needle",.regex)),
                  .any([.rule(.name("needle",.contains)),.rule(.name("other",.contains))]),
                  .any([.rule(.name("needle",.contains)),.none([.rule(.name("other",.contains))])]),
                  .all([.rule(.name("needle",.contains)),.none([.rule(.extensions(["md"]))])])] {
        var request = fossRequest(scope,"",mode:.files); request.useIndex = true; request.includeHidden = true; request.state.replaceRules(.init(files:files))
        let pipeline = try SearchPipelineCompiler(tools:.resolve()).compile(request,source:source)
        let optimized = try await ProcessRunner.run(spec:pipeline.spec,pathOverride:Toolchain.resolve().searchPath)
        let scan = try await ProcessRunner.run(spec:SearchPipelineCompiler(tools:.resolve()).compile(request,source:scanSource).spec,pathOverride:Toolchain.resolve().searchPath)
        #expect(optimized.exitCode == 0 && optimized.stdout.split(separator: "\0").sorted() == scan.stdout.split(separator: "\0").sorted(),"\(optimized.stderr)")
    }
    let loaded = try IndexArtifact.load(db)
    let oldFile = scope.appendingPathComponent("Needle.txt"), renamed = scope.appendingPathComponent("renamed.txt")
    try FileManager.default.moveItem(at:oldFile,to:renamed)
    let update = try await service.refreshIndex(loaded,changes:[.init(path:oldFile.path,recursive:false),.init(path:renamed.path,recursive:false)])
    try IndexArtifact(metadata:update.metadata,entries:update.entries,catalog:update.catalog,delta:update.delta).save(db)
    let current = try IndexArtifact.load(db,includeEntries:false)
    var renamedQuery = fossRequest(scope,"renamed",mode:.files); renamedQuery.useIndex = true; renamedQuery.includeHidden = true
    #expect(try await service.search(request:renamedQuery,index:current.metadata,entries:current.entries).results.map(\.name) == ["renamed.txt"])
    renamedQuery.query = "Needle.txt"
    #expect(try await service.search(request:renamedQuery,index:current.metadata,entries:current.entries).results.isEmpty)
}

@Test func filteredWordUpdatesPreserveOtherScopesAndIgnoreTheirOwnCache() async throws {
    let root = try fossRoot(); defer { try? FileManager.default.removeItem(at:root) }
    let scope = root.appendingPathComponent("files"), cache = scope.appendingPathComponent("generated-cache")
    try FileManager.default.createDirectory(at:scope,withIntermediateDirectories:true)
    for name in ["alpha.txt","beta.txt"] { try Data("needle".utf8).write(to:scope.appendingPathComponent(name)) }
    let old = ProcessInfo.processInfo.environment["FINDUI_CACHE_DIRECTORY"]
    setenv("FINDUI_CACHE_DIRECTORY",cache.path,1)
    defer { if let old { setenv("FINDUI_CACHE_DIRECTORY",old,1) } else { unsetenv("FINDUI_CACHE_DIRECTORY") } }
    var preparation = fossRequest(scope); preparation.buildWordIndex = true; preparation.includeHidden = true
    func prepare(_ request:SearchRequest) async throws -> ProcessExecution {
        try await ProcessRunner.run(spec:SearchPipelineCompiler(tools:.resolve()).compile(request).spec,pathOverride:Toolchain.resolve().searchPath)
    }
    #expect(try await prepare(preparation).exitCode == 0)
    var query = preparation; query.buildWordIndex = false; query.refinements.wordSearch = true
    #expect(try await WordIndexService.status(query).state == "updated")
    #expect(try await WordIndexService.status(query).sources == 2)
    try FileManager.default.removeItem(at:scope.appendingPathComponent("beta.txt"))
    var filtered = preparation; filtered.refinements.name = "alpha"
    let update = try await prepare(filtered)
    #expect(update.exitCode == 0 && update.stderr.contains("\"sourcesPruned\":0"),"\(update.stderr)")
    query.refinements.name = "alpha"
    #expect(try await WordIndexService.status(query).state == "updated")
    let full = try await prepare(preparation)
    #expect(full.exitCode == 0 && full.stderr.contains("\"sourcesPruned\":1"),"\(full.stderr)")
    let other = root.appendingPathComponent("offline")
    try FileManager.default.moveItem(at:scope,to:other)
    // Keep the cache reachable while its source folder is unavailable.
    setenv("FINDUI_CACHE_DIRECTORY",other.appendingPathComponent("generated-cache").path,1)
    #expect(try await WordIndexService.status(query).state == "unavailable")
}

@Test func vocabularySuggestionsAndResultFacetsKeepExistingQueries() async throws {
    let root = try fossRoot(); defer { try? FileManager.default.removeItem(at:root) }
    let old = ProcessInfo.processInfo.environment["FINDUI_CACHE_DIRECTORY"]
    setenv("FINDUI_CACHE_DIRECTORY",root.appendingPathComponent("cache").path,1)
    defer { if let old { setenv("FINDUI_CACHE_DIRECTORY",old,1) } else { unsetenv("FINDUI_CACHE_DIRECTORY") } }
    let scope = root.appendingPathComponent("scope")
    try FileManager.default.createDirectory(at:scope,withIntermediateDirectories:true)
    for (name,text) in [("alpha.txt","needle nearby"),("beta.md","neptune")] { try Data(text.utf8).write(to:scope.appendingPathComponent(name)) }
    var request = fossRequest(scope); request.buildWordIndex = true
    #expect(try await ProcessRunner.run(spec:SearchPipelineCompiler(tools:.resolve()).compile(request).spec,pathOverride:Toolchain.resolve().searchPath).exitCode == 0)
    request.buildWordIndex = false; request.refinements.wordSearch = true
    let suggestions = try await WordIndexService.suggestions(request,prefix:"ne")
    #expect(Set(suggestions.map(\.text)) == ["needle","nearby","neptune"])
    let state = request.state
    let facet = ResultFacet(kind:.fileType,value:"txt",count:1)
    let narrowed = try facet.applying(to:state)
    #expect(narrowed.contentsInput == state.contentsInput && narrowed.refinements.wordSearch == true)
    #expect(try await SearchService().search(request:narrowed.makeRequest()).results.map(\.name) == ["alpha.txt"])
    let readers = try await ReaderRegistry.load()
    #expect(readers.first { $0.id == "mail" }?.ready == true)
    #expect(readers.first { $0.id == "office" }?.formats.contains("xlsx") == true)
    #expect(!readers.flatMap(\.formats).contains("png"))
}
