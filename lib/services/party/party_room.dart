/// 「一起看」的房间状态与传输格式。
///
/// 设计为**主机权威**：只有房主的播放进度会被广播，其他人（观众）跟随。
/// 这样不需要处理多方同时拖动进度带来的冲突，也避免观众的口误操作影响全房间。
class PartyState {
  const PartyState({
    this.title = '',
    this.episodeName = '',
    this.episodeIndex = 0,
    this.positionMs = 0,
    this.playing = false,
    this.updatedAt = 0,
    this.sender = '',
  });

  /// 剧名（观众可据此确认自己开的是同一部片子）。
  final String title;
  final String episodeName;
  final int episodeIndex;
  final int positionMs;
  final bool playing;

  /// 状态生成时间（毫秒时间戳）；观众用它与本地已应用的状态比较新旧。
  final int updatedAt;

  /// 发送方设备名。
  final String sender;

  PartyState copyWith({
    String? title,
    String? episodeName,
    int? episodeIndex,
    int? positionMs,
    bool? playing,
    int? updatedAt,
    String? sender,
  }) => PartyState(
    title: title ?? this.title,
    episodeName: episodeName ?? this.episodeName,
    episodeIndex: episodeIndex ?? this.episodeIndex,
    positionMs: positionMs ?? this.positionMs,
    playing: playing ?? this.playing,
    updatedAt: updatedAt ?? this.updatedAt,
    sender: sender ?? this.sender,
  );

  Map<String, dynamic> toJson() => {
    'title': title,
    'episodeName': episodeName,
    'episodeIndex': episodeIndex,
    'positionMs': positionMs,
    'playing': playing,
    'updatedAt': updatedAt,
    'sender': sender,
  };

  factory PartyState.fromJson(Map<String, dynamic> json) => PartyState(
    title: (json['title'] ?? '').toString(),
    episodeName: (json['episodeName'] ?? '').toString(),
    episodeIndex: (json['episodeIndex'] as num?)?.toInt() ?? 0,
    positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
    playing: json['playing'] == true,
    updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
    sender: (json['sender'] ?? '').toString(),
  );
}

/// 房主进程内的房间数据（局域网服务直接读它）。
class PartyRoom {
  String code = '';
  String hostName = '';
  PartyState? state;

  /// 每次发布 +1，观众可据此判断是否有新状态（比时间戳更稳）。
  int revision = 0;

  bool get open => code.isNotEmpty && state != null;

  void publish(PartyState next) {
    state = next;
    revision++;
  }

  void clear() {
    code = '';
    hostName = '';
    state = null;
    revision = 0;
  }

  Map<String, dynamic> toJson() => {
    'ok': open,
    'host': hostName,
    'revision': revision,
    if (state != null) 'state': state!.toJson(),
  };
}
