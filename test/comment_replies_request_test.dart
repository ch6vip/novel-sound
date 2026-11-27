import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 书评回复的命名空间（`comment_source`）按官方 7.0.9.32 抓包固定在请求里：
/// 书评 501、段评 503。传错不会报错，只会拿到空列表，所以这里把它钉住。
void main() {
  late List<Uri> requests;

  ApiClient buildClient() {
    requests = <Uri>[];
    final transport = MockClient((request) async {
      requests.add(request.url);
      return http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'code': 0,
            'data': {
              'reply_list': <dynamic>[],
              'comment_list_info': {'total': 0},
            },
          }),
        ),
        200,
      );
    });
    addTearDown(transport.close);
    return ApiClient(client: transport, baseUrl: 'http://localhost:9000');
  }

  test('书评回复默认走 501 命名空间，一次取 20 条', () async {
    final api = buildClient();
    await api.commentReplies('book-1', 'comment-1', groupId: 'book-1');

    final url = requests.single;
    expect(url.path, '/api/v1/comments/comment-1/replies');
    expect(url.queryParameters['comment_source'], '501');
    expect(url.queryParameters['count'], '20');
    expect(url.queryParameters['book_id'], 'book-1');
    expect(url.queryParameters['group_id'], 'book-1');
  });

  test('段评回复切到 503 命名空间', () async {
    final api = buildClient();
    await api.commentReplies(
      'book-1',
      'comment-1',
      groupId: 'book-1',
      commentSource: 503,
    );

    expect(requests.single.queryParameters['comment_source'], '503');
  });

  test('段评回复可显式指定 (comment_type, group_type, server_channel) 与段落上下文', () async {
    final api = buildClient();
    await api.commentReplies(
      'book-1',
      'comment-1',
      groupId: 'item-1',
      commentSource: 503,
      commentType: 1,
      groupType: 1,
      serverChannel: 38,
      itemId: 'item-1',
      paraIndex: 7,
      itemVersion: 'ver-1',
    );

    final query = requests.single.queryParameters;
    expect(query['comment_source'], '503');
    // 段评回复真正有数据的组合（503/1/1/38），错一个上游就回空列表。
    expect(query['comment_type'], '1');
    expect(query['group_type'], '1');
    expect(query['server_channel'], '38');
    // 段落上下文原样透传，书评调用方不传即保持旧请求体。
    expect(query['item_id'], 'item-1');
    expect(query['para_index'], '7');
    expect(query['item_version'], 'ver-1');
  });

  test('不传新参数时请求体与旧版本保持一致', () async {
    final api = buildClient();
    await api.commentReplies('book-1', 'comment-1', groupId: 'book-1');

    final query = requests.single.queryParameters;
    expect(query.containsKey('comment_type'), isFalse);
    expect(query.containsKey('group_type'), isFalse);
    expect(query.containsKey('server_channel'), isFalse);
    expect(query.containsKey('item_id'), isFalse);
    expect(query.containsKey('para_index'), isFalse);
    expect(query.containsKey('item_version'), isFalse);
  });
}
