/// How one version of a record relates to another.
enum Descent {
  /// The same version.
  same,

  /// An older version: the other one was made from this one.
  older,

  /// A newer version, made from the other one.
  newer,

  /// Made on two machines from a common older version, neither knowing
  /// about the other's change.
  concurrent,
}

/// Counts how many times each machine has saved a record.
///
/// Every upload adds one to the uploading machine's count, after taking the
/// highest count of each machine it has seen. So a version that has seen
/// another has counts at least as high everywhere, and two versions made
/// without seeing each other each have a count the other lacks.
class VersionVector {
  const VersionVector([this.counts = const {}]);

  factory VersionVector.fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('A version must be a map of counts');
    }
    return VersionVector({
      for (final MapEntry(:key, :value) in json.entries)
        if (value is int && value > 0)
          key: value
        else
          key: throw FormatException('Bad count for $key: $value'),
    });
  }

  final Map<String, int> counts;

  bool get isEmpty => counts.isEmpty;

  /// How this version relates to [other].
  Descent compareTo(VersionVector other) {
    var behind = false;
    var ahead = false;
    for (final device in {...counts.keys, ...other.counts.keys}) {
      final mine = counts[device] ?? 0;
      final theirs = other.counts[device] ?? 0;
      if (mine < theirs) behind = true;
      if (mine > theirs) ahead = true;
    }
    return switch ((behind, ahead)) {
      (false, false) => Descent.same,
      (true, false) => Descent.older,
      (false, true) => Descent.newer,
      (true, true) => Descent.concurrent,
    };
  }

  /// The highest count of each machine in this version and [other].
  VersionVector merge(VersionVector other) => VersionVector({
    ...counts,
    for (final MapEntry(:key, :value) in other.counts.entries)
      if (value > (counts[key] ?? 0)) key: value,
  });

  /// This version with one more save by [device].
  VersionVector bump(String device) =>
      VersionVector({...counts, device: (counts[device] ?? 0) + 1});

  Map<String, int> toJson() => counts;

  @override
  bool operator ==(Object other) =>
      other is VersionVector && compareTo(other) == Descent.same;

  @override
  int get hashCode => Object.hashAllUnordered(
    counts.entries.map((e) => Object.hash(e.key, e.value)),
  );

  @override
  String toString() => 'VersionVector($counts)';
}
