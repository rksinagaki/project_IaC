import pytest
from unittest.mock import patch, MagicMock
import json
import os

from src.lambda.lambda_test import lambda_handler
# from src.lambda.lambda_test import get_youtube_api_key, get_channel, get_video, lambda_handler


# チャンネル情報APIレスポンスのモック
MOCK_CHANNEL_RESPONSE = {
    'items': [{
        'id': 'UC_TESTID',
        'snippet': {
            'title': 'Test Channel',
            'publishedAt': '2020-01-01T00:00:00Z'
        },
        'statistics': {
            'subscriberCount': '1000',
            'viewCount': '50000',
            'videoCount': '50'
        }
    }]
}

# 動画情報APIレスポンスのモック
MOCK_VIDEO_RESPONSE = {
    'items': [{
        'id': 'video_test',
        'snippet': {
            'title': 'Video 1',
            'publishedAt': '2023-01-01T00:00:00Z',
            'tags': ['tag_test']
        },
        'statistics': {
            'viewCount': '100',
            'likeCount': '10',
            'commentCount': '5'
        },
        'contentDetails': {'duration': 'PT10M'}
        }
    ]
}

# SecretsManagerのモック化テスト
@patch('src.lambda.lambda_test.secretsmanager_client')
def test_get_youtube_api_key_success(mock_secretsmanager):
    mock_secretsmanager.get_secret_value.return_value = {
        'SecretString': json.dumps({'API_KEY': 'MOCK_KEY_123'})
    }
    key = get_youtube_api_key("test-arn")

    assert key == 'MOCK_KEY_123'
    pass
    
# YouTube API呼び出し部分のみをモック化
@patch('src.lambda.lambda_test.youtube')
def test_get_channel_data_integrity(mock_youtube):
    mock_youtube.channels.return_value.list.return_value.execute.return_value = MOCK_CHANNEL_RESPONSE
    channel_list = get_channel('UC_TESTID')

    assert len(channel_list) == 1
    assert channel_list[0]['channel_id'] == 'UC_TESTID'
    assert isinstance(channel_list[0]['subscriber_count'], int)
    assert channel_list[0]['subscriber_count'] == 1000
    pass

# lambda_handlerのオーケストレーション検証 (S3/EventBridge呼び出し)
@patch('src.lambda.lambda_test.boto3.client')
@patch('src.lambda.lambda_test.youtube')
@patch('src.lambda.lambda_test.get_channel', return_value=[{'channel_id': 'UC_T', 'data': 'channel'}])
@patch('src.lambda.lambda_test.get_video', return_value=[{'video_id': 'v1', 'view_count': 100, 'title': 'Test Video'}])
@patch('src.lambda.lambda_test.get_comments_for_video', return_value=[{'comment_id': 'c1'}])
@patch.dict(os.environ, {'BUCKET_NAME': 'MOCK_BUCKET', 'REGION_NAME': 'ap-northeast-1'}, clear=True) # 環境変数をモック
def test_handler_s3_and_eventbridge_called(mock_get_comments, mock_get_video, mock_get_channel, mock_youtube, mock_boto_client):

    # 準備: S3とEventsの偽物（モック）を作成
    mock_s3 = MagicMock()
    mock_events = MagicMock()

    # boto3.client('s3') が呼ばれたら mock_s3 を、boto3.client('events') が呼ばれたら mock_events を返す
    mock_boto_client.side_effect = lambda service, **kwargs: {
        's3': mock_s3,
        'events': mock_events,
        # secretsmanager_clientはグローバルで初期化済みのため、ここではスキップ
    }.get(service)
    
    event = {"CHANNEL_ID": "UC_TEST", "ARTIST_NAME_DISPLAY": "Test Artist", "ARTIST_NAME_SLUG": "test-slug"}
    context = MagicMock(aws_request_id="MOCK_EXECUTION_ID")
    
    response = lambda_handler(event, context)
    
    # 1. S3への保存が3回 (チャンネル, 動画, コメント) 実行されたこと
    assert mock_s3.put_object.call_count == 3
    
    # 2. EventBridgeへの情報引き継ぎが1回実行されたこと
    mock_events.put_events.assert_called_once()
    
    # 3. Lambdaが成功レスポンスを返したこと
    assert response['statusCode'] == 200