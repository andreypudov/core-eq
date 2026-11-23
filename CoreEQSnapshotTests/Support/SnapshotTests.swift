import Testing

/// Every snapshot suite, one test at a time.
///
/// They share things only one test can use at once: the main run loop each
/// view settles on, the engine bridge the Settings panes read, and the network
/// stub the AutoEQ window downloads through. Run side by side, one test's view
/// could settle while another changed what it shows.
@Suite(.serialized)
enum SnapshotTests {}
