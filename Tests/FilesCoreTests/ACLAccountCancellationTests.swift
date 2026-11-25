import Foundation
import Testing
@testable import FilesCore

@Test(arguments: [FileACLAccountKind.user, .group])
func cancelledAccountEnumerationDoesNotPublishNames(kind: FileACLAccountKind) async {
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await kind.accountNames()
    }
    #expect(await task.value.isEmpty)
    let names = await kind.accountNames()
    #expect(!names.isEmpty)
    #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
}
