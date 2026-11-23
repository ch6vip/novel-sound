part of '../pages/audio_page.dart';

/// One paused player buffers the next chapter while the current one finishes.
class _AudioPreload {
  _AudioPreload(this.itemId, this.toneId, this.player);

  final String itemId;
  final String toneId;
  final NativePlayer player;
  AudioSource? source;
  bool prepared = false;
  bool cancelled = false;
  Future<void>? _disposal;

  Future<void> dispose() {
    cancelled = true;
    return _disposal ??= player.dispose().catchError((Object _) {});
  }
}

extension _AudioPlaybackPreload on _AudioPlaybackController {
  void _prefetchNextAudioChapter() {
    if (request.sourceLoader != null ||
        !_autoAdvance ||
        _index + 1 >= _chapters.length) {
      return;
    }
    final nextId = _chapters[_index + 1].itemId;
    final cacheKey = '$nextId|$_toneId';
    if (_audioSourceCache.containsKey(cacheKey)) return;
    _loadSourceWithRetry(nextId).ignore();
  }

  /// Join a pending fetch for the same chapter and voice. A manual retry
  /// must bypass both the cached address and any speculative in-flight fetch.
  Future<AudioSource> _loadSourceWithRetry(
    String itemId, {
    bool refresh = false,
  }) {
    final bookId = _bookId;
    final toneId = _toneId;
    final key = '$bookId|$itemId|$toneId';
    if (refresh) {
      _audioSourceRequests.removeWhere(
        (key, _) => key.startsWith('$bookId|$itemId|'),
      );
    }
    return _audioSourceRequests.putIfAbsent(key, () {
      late final Future<AudioSource> request;
      request = _loadAudioSource(itemId, bookId, toneId, refresh: refresh)
          .whenComplete(() {
            if (identical(_audioSourceRequests[key], request)) {
              _audioSourceRequests.remove(key);
            }
          });
      return request;
    });
  }

  Future<AudioSource> _loadAudioSource(
    String itemId,
    String bookId,
    String requestedTone, {
    required bool refresh,
  }) async {
    final generation = _generation;
    // Offline downloads are authoritative, including on manual retry.
    final local = await _localSource(itemId, requestedTone);
    if (local != null) {
      AppLog.d('audio', 'event=source origin=local');
      return local;
    }
    final loader = request.sourceLoader;
    if (loader != null) {
      return loader(
        itemId,
        toneId: requestedTone,
      ).timeout(const Duration(seconds: 30));
    }
    final cacheKey = '$itemId|$requestedTone';
    if (refresh) {
      _audioSourceCache.removeWhere((key, _) => key.startsWith('$itemId|'));
    }
    final cached = _audioSourceCache[cacheKey];
    if (cached != null) {
      AppLog.d('audio', 'event=source origin=cache');
      return cached;
    }
    AppLog.d('audio', 'event=source origin=network refresh=$refresh');
    AudioSource result;
    try {
      result = await _fetchSource(itemId, requestedTone, bookId: bookId);
    } on ApiException catch (error) {
      if (requestedTone != '0' ||
          !error.message.contains('NO_THIS_TONE') ||
          _closed ||
          _bookId != bookId) {
        rethrow;
      }
      final fallback = _firstSelectableTone();
      if (fallback == null) rethrow;
      // A speculative voice fallback must not alter the current chapter's UI.
      if (_current(generation) &&
          _chapters[_index].itemId == itemId &&
          _toneId == requestedTone) {
        _toneSwitchedForChapter = true;
      }
      result = await _fetchSource(itemId, fallback, bookId: bookId);
    }
    // An earlier fetch must not restore the stale URL after a manual retry.
    if (_current(generation)) {
      _audioSourceCache[cacheKey] = result;
      while (_audioSourceCache.length > 5) {
        _audioSourceCache.remove(_audioSourceCache.keys.first);
      }
    }
    return result;
  }

  void _prepareNextAudio() {
    final current = _player;
    if (_closed ||
        _loading ||
        _completed ||
        !_wantPlay ||
        !_autoAdvance ||
        _sleepAtChapterEnd ||
        _switchingVersion ||
        (isIOSPlatform && !_appActive) ||
        current == null ||
        !current.playing ||
        current.buffering ||
        _duration <= Duration.zero ||
        _index + 1 >= _chapters.length) {
      return;
    }
    final remaining =
        _duration -
        _position.value -
        Duration(seconds: _skipPoints.outroSeconds);
    if (remaining <= Duration.zero ||
        remaining.inMilliseconds > 30000 * _rate) {
      return;
    }
    final nextId = _chapters[_index + 1].itemId;
    if (_audioPreload?.itemId == nextId && _audioPreload?.toneId == _toneId) {
      return;
    }
    unawaited(_dropAudioPreload());
    final preload = _audioPreload = _AudioPreload(
      nextId,
      _toneId,
      request.playerFactory?.call() ?? NativePlayer(audioOnly: true),
    );
    unawaited(() async {
      try {
        final source = await _loadSourceWithRetry(nextId);
        if (preload.cancelled) return;
        final uri = Uri.tryParse(source.url);
        if (source.itemId != nextId ||
            uri == null ||
            !(uri.scheme == 'file' ||
                (const ['http', 'https'].contains(uri.scheme) &&
                    uri.host.isNotEmpty))) {
          throw const FormatException('Invalid audio source');
        }
        preload.source = source;
        // Native create prepares the media while playWhenReady stays false.
        await preload.player.create(source.url, source.keyHex);
        if (preload.cancelled || preload.player.lastError != null) {
          await preload.dispose();
          return;
        }
        preload.prepared = true;
      } catch (_) {
        await preload.dispose();
      }
    }());
  }

  _AudioPreload? _takeAudioPreload(String itemId, String toneId) {
    final preload = _audioPreload;
    if (preload == null) return null;
    if (preload.cancelled || preload.player.lastError != null) {
      _audioSourceCache.remove('${preload.itemId}|${preload.toneId}');
    }
    if (preload.itemId != itemId ||
        preload.toneId != toneId ||
        !preload.prepared ||
        preload.cancelled ||
        preload.player.lastError != null) {
      unawaited(_dropAudioPreload());
      return null;
    }
    _audioPreload = null;
    return preload;
  }

  Future<void> _dropAudioPreload() {
    final preload = _audioPreload;
    _audioPreload = null;
    return preload?.dispose() ?? Future<void>.value();
  }
}
