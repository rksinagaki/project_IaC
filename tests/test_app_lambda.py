import pytest
from unittest.mock import patch, MagicMock
import json
import os
from src.lambda_func.app_lambda import get_youtube_api_key, get_channel, get_video, lambda_handler
# from src.clean_up.clean_up_lambda import delete_s3_prefix, lambda_handler

# SecretsManagerのモック化テスト
@patch('src.lambda_func.app_lambda.boto3.client') 
def test_get_youtube_api_key_success(mock_boto_client):
    mock_secretsmanager_client = mock_boto_client.return_value
    
    TEST_API_KEY = "dummy_test_api_key_123"
    mock_secretsmanager_client.get_secret_value.return_value = {
        'SecretString': json.dumps({"API_KEY": TEST_API_KEY})
    }

    result = get_youtube_api_key("dummy_arn")

    assert result == TEST_API_KEY

# get_channelモジュールテスト
def test_get_channel_success():
    mock_youtube_client = MagicMock()
    
    TEST_CHANNEL_ID = "UC_test_ID_456"
    
    mock_api_response = {
        "items": [
            {
                "id": TEST_CHANNEL_ID,
                "snippet": {
                    "title": "テストチャンネル", 
                    "publishedAt": "2023-10-25T00:00:00Z"
                },
                "statistics": {
                    "subscriberCount": "1000",
                    "viewCount": "1000",
                    "videoCount": "1000"
                }
            }
        ]
    }
    
    mock_youtube_client.channels.return_value.list.return_value.execute.return_value = mock_api_response

    result = get_channel(mock_youtube_client, TEST_CHANNEL_ID)

    channel_info = result[0]
    
    assert channel_info["channel_id"] == TEST_CHANNEL_ID
    assert channel_info["channel_name"] == "テストチャンネル"
    assert channel_info["subscriber_count"] == 1000
    assert channel_info["video_count"] == 1000

# lambda_handlerモジュールのテスト
@patch('src.lambda_func.app_lambda.get_comments_for_video')
@patch('src.lambda_func.app_lambda.get_video')
@patch('src.lambda_func.app_lambda.get_channel')
@patch('src.lambda_func.app_lambda.get_youtube_api_key')
@patch('src.lambda_func.app_lambda.build')
@patch('src.lambda_func.app_lambda.boto3.client')
@patch('src.lambda_func.app_lambda.pd.DataFrame')
def test_lambda_handler_success(
    mock_df,
    mock_boto_client,
    mock_build,
    mock_get_api_key,
    mock_get_channel,
    mock_get_video,
    mock_get_comments,
):

    mock_get_api_key.return_value = "DUMMY_API_KEY"

    mock_youtube_client = MagicMock()
    mock_build.return_value = mock_youtube_client
    
    mock_get_channel.return_value = [{"channel_id": "UC_TEST"}]

    video_data = [
        {"video_id": "v1", "view_count": 50000},
        {"video_id": "v2", "view_count": 10000},
    ]
    mock_get_video.return_value = video_data

    mock_get_comments.return_value = [{"comment_id": "c1"}]

    mock_df_instance = MagicMock()
    mock_df.return_value = mock_df_instance
    
    mock_s3_client = MagicMock()
    mock_events_client = MagicMock()
    def boto_client_side_effect(service_name, **kwargs):
        if service_name == "s3":
            return mock_s3_client
        if service_name == "events":
            return mock_events_client
        return MagicMock()
        
    mock_boto_client.side_effect = boto_client_side_effect
    
    TEST_EVENT = {
        "CHANNEL_ID": "UC_TEST_ID",
        "ARTIST_NAME_DISPLAY": "Test Artist",
        "ARTIST_NAME_SLUG": "test_artist_slug",
        "POWERTOOLS_SERVICE_NAME": "youtube-scraper"
    }
    mock_context = MagicMock()
    mock_context.aws_request_id = "test-execution-id" 

    response = lambda_handler(TEST_EVENT, mock_context)

    mock_get_api_key.assert_called_once_with(os.environ["YOUTUBE_API_KEY_ARN"])
    mock_build.assert_called_once_with("youtube", "v3", developerKey="DUMMY_API_KEY")
    mock_get_channel.assert_called_once_with(mock_youtube_client, TEST_EVENT["CHANNEL_ID"])
    mock_get_video.assert_called_once_with(mock_youtube_client, TEST_EVENT["CHANNEL_ID"])
    
    mock_boto_client.assert_any_call("s3", region_name=os.environ["REGION_NAME"])
    
    assert mock_s3_client.put_object.call_count == 3

    mock_events_client.put_events.assert_called_once()
    
    put_events_args = mock_events_client.put_events.call_args[1]["Entries"][0]
    assert put_events_args["Source"] == "my-scraper"
    assert put_events_args["DetailType"] == "ScrapingCompleted"
    assert put_events_args["EventBusName"] == "youtube-pipeline-event-bus"
    assert response["statusCode"] == 200
