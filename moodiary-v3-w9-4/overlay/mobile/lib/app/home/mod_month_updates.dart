import 'dart:async';

/// App-lifetime invalidations shared by native and LAN commits. No document data.
class ModMonthUpdates {
  static final _controller = StreamController<String>.broadcast(sync: true);
  static Stream<String> get changes => _controller.stream;
  static void publish(String topicId) => _controller.add(topicId);
}
