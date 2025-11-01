import pytest
from unittest.mock import patch, MagicMock
import os
import json
from src.lambda.lambda_test import lambda_handler, get_channel, get_video #なぜか読み込めない

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

# 動画情報APIレスポンスのモック (シンプル版)
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
@patch('src.lambda.handler.secretsmanager_client')
def test_get_youtube_api_key_success(mock_secretsmanager):
    mock_secretsmanager.get_secret_value.return_value = {
        'SecretString': json.dumps({'API_KEY': 'MOCK_KEY_123'})
    } 
    from src.lambda.handler import get_youtube_api_key
    key = get_youtube_api_key("test-arn")

    assert key == 'MOCK_KEY_123'
    pass
    
# YouTube API呼び出し部分のみをモック化
@patch('src.lambda.handler.youtube.channels')
def test_get_channel_data_integrity(mock_youtube_channels):
    mock_youtube_channels.return_value.list.return_value.execute.return_value = MOCK_CHANNEL_RESPONSE
    
    channel_list = get_channel('UC_TESTID')

    assert len(channel_list) == 1
    assert channel_list[0]['channel_id'] == 'UC_TESTID'
    assert isinstance(channel_list[0]['subscriber_count'], int)
    assert channel_list[0]['subscriber_count'] == 1000
    pass

@patch('src.lambda.handler.youtube.channels')
@patch('src.lambda.handler.youtube.videos')
@patch('src.lambda.handler.youtube.playlistItems')
def test_get_video_data_integrity(mock_playlist_items, mock_videos, mock_channels):
    pass # 実際に動画APIのモックを設定して検証コードを記述

# S3, EventBridge, SecretsManager, YouTube APIをまとめてモック化
@patch('src.lambda.lambda_test.boto3.client') # 💡 boto3.clientをモック化
@patch('src.lambda.lambda_test.get_comments_for_video', return_value=[{'comment_id': 'c1'}])
# ... (他のモックも必要に応じて修正)
def test_lambda_handler_orchestration(mock_comments, mock_boto_client): # 引数も変更
    
    # 💡 修正: モック化したboto3.clientが、どのサービスを呼ばれたかによって偽のクライアントを返すように設定
    mock_s3 = MagicMock()
    mock_events = MagicMock()
    
    # boto3.client('s3') が呼ばれたら mock_s3 を、boto3.client('events') が呼ばれたら mock_events を返すように設定
    mock_boto_client.side_effect = lambda service, **kwargs: {
        's3': mock_s3,
        'events': mock_events,
        'secretsmanager': MagicMock(), # secretsmanagerもここで偽装可能
    }.get(service)

    # ... (以降の検証は、mock_s3.put_object や mock_events.put_events を使用) ...
    
    # 1. S3への保存が3回実行されたこと
    assert mock_s3.put_object.call_count == 3
    
    # 2. EventBridgeへの情報引き継ぎが実行されたこと
    mock_events.put_events.assert_called_once()


# S3, EventBridge, SecretsManager, YouTube APIをまとめてモック化
@patch('src.lambda.handler.s3')
@patch('src.lambda.handler.events_client')
@patch('src.lambda.handler.get_youtube_api_key', return_value='MOCK_KEY')
@patch('src.lambda.handler.youtube')
@patch('src.lambda.handler.get_channel', return_value=[{'channel_id': 'UC_T', 'data': 'channel'}])
@patch('src.lambda.handler.get_video', return_value=[{'video_id': 'v1', 'view_count': 100}])
@patch('src.lambda.handler.get_comments_for_video', return_value=[{'comment_id': 'c1'}])
def test_lambda_handler_orchestration(mock_comments, mock_videos, mock_channel, mock_youtube, mock_api_key, mock_events, mock_s3):

    # --- 準備 ---
    mock_s3.put_object = MagicMock()
    mock_events.put_events = MagicMock()
    
    # Lambdaへの入力イベント
    event = {
        "CHANNEL_ID": "UC_TEST",
        "ARTIST_NAME_DISPLAY": "Test Artist",
        "ARTIST_NAME_SLUG": "test-artist"
    }
    # contextオブジェクトのモック
    context = MagicMock(aws_request_id="MOCK_EXECUTION_ID")
    
    # --- 実行 ---
    response = lambda_handler(event, context)
    
    # --- 検証 ---
    
    # 1. S3への保存が3回実行されたこと
    assert mock_s3.put_object.call_count == 3
    
    # 2. EventBridgeへの情報引き継ぎが実行されたこと
    mock_events.put_events.assert_called_once()
    
    # 3. EventBridgeに渡されたデータに重要な情報が含まれているか
    call_args = mock_events.put_events.call_args[0][0]['Entries'][0]['Detail']
    detail = json.loads(call_args)
    
    # 💡 SFNに引き渡すべき情報が正しく含まれているか確認
    assert detail['statusCode'] == 200
    assert 's3://BUCKET_NAME/channel=UC_TEST/workflow=MOCK_EXECUTION_ID/raw_data/data_channel.json' in detail['input_keys'][0]
    assert detail['artist_name_slug'] == "test-artist"

    # 4. Lambdaが成功レスポンスを返したこと
    assert response['statusCode'] == 200