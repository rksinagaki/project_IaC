import logging
import json
import os
from io import StringIO
import boto3
import pandas as pd
from googleapiclient.discovery import build
from aws_lambda_powertools import Logger

secretsmanager_client = boto3.client('secretsmanager')
SECRET_ARN = os.environ.get('YOUTUBE_API_KEY_ARN')

# シークレットを取得する関数
def get_youtube_api_key(secret_arn):
    response = secretsmanager_client.get_secret_value(SecretId=secret_arn)
    secret_data = json.loads(response['SecretString'])
    return secret_data['API_KEY']

# /////////////////
# 環境変数読み込み
# /////////////////
#CHANNEL_ID = os.environ.get("CHANNEL_ID")
# API_KEY = os.environ.get("API_KEY")
BUCKET_NAME = os.environ.get('data_bucket_name')
REGION_NAME = os.environ.get('region_name')
API_KEY = get_youtube_api_key(SECRET_ARN)

youtube = build('youtube',
                'v3',
                developerKey=API_KEY
                )
logger = Logger()

# /////////////////
# チャンネル情報の取得
# /////////////////
def get_channel(channel_id):
    channels_response = youtube.channels().list(
            part='snippet,statistics',
            id=channel_id
        ).execute()

    channel_data = channels_response['items'][0]
    
    channel_info = {
        'channel_id': channel_data['id'],
        'channel_name': channel_data['snippet']['title'],
        'subscriber_count': int(channel_data['statistics'].get('subscriberCount', 0)),
        'total_views': int(channel_data['statistics'].get('viewCount', 0)),
        'video_count': int(channel_data['statistics'].get('videoCount', 0)),
        'published_at': channel_data['snippet']['publishedAt']
    }

    channel_list = [channel_info]

    return channel_list

# /////////////////
# 動画情報の取得
# /////////////////
def get_video(channel_id):
    channels_response = youtube.channels().list(
            part='statistics, contentDetails, brandingSettings',
            id=channel_id
        ).execute()

    playlist_id = channels_response['items'][0]['contentDetails']['relatedPlaylists']['uploads']
    all_videos_data = []
    next_page_token = None

    while True:
        playlist_response = youtube.playlistItems().list(
            part='snippet,contentDetails',
            playlistId=playlist_id,
            maxResults=50,
            pageToken=next_page_token
        ).execute()

        video_ids = []
        for item in playlist_response['items']:
            video_ids.append(item['contentDetails']['videoId'])

        if video_ids:
            videos_response = youtube.videos().list(
                part='snippet,statistics,contentDetails',
                id=','.join(video_ids)
            ).execute()

            for video_data in videos_response['items']:
                video_id = video_data['id']
                title = video_data['snippet']['title']
                published_at = video_data['snippet']['publishedAt']
                view_count = video_data['statistics'].get('viewCount', 0)
                like_count = video_data['statistics'].get('likeCount', 0)
                comment_count = video_data['statistics'].get('commentCount', 0)
                duration = video_data['contentDetails']['duration']
                tags = video_data['snippet'].get('tags', [])

                all_videos_data.append({
                    'video_id': video_id,
                    'title': title,
                    'published_at': published_at,
                    'view_count': int(view_count),
                    'like_count': int(like_count),
                    'comment_count': int(comment_count),
                    'duration': duration,
                    'tags': ','.join(tags)
                })

        next_page_token = playlist_response.get('nextPageToken')

        if not next_page_token:
            break

    return all_videos_data

# /////////////////
# アップロードした動画のIDを取得
# /////////////////
def get_uploads_playlist_id(channel_id):
    channels_response = youtube.channels().list(
        part='contentDetails',
        id=channel_id
    ).execute()
    return channels_response['items'][0]['contentDetails']['relatedPlaylists']['uploads']

# /////////////////
# コメント情報の取得
# /////////////////
def get_comments_for_video(video_id, max_comments_per_video=100):
    comments_data = []
    
    comment_threads_response = youtube.commentThreads().list(
        part='snippet',
        videoId=video_id,
        maxResults=min(100, max_comments_per_video),
        pageToken=None,
        order='relevance'
    ).execute()

    for item in comment_threads_response['items']:
        comment = item['snippet']['topLevelComment']['snippet']
        comments_data.append({
            'video_id': video_id,
            'comment_id': item['id'],
            'author_display_name': comment['authorDisplayName'],
            'published_at': comment['publishedAt'],
            'text_display': comment['textDisplay'],
            'like_count': comment['likeCount']
        })
    
    return comments_data

# /////////////////
# lambda関数実行
# /////////////////
def lambda_handler(event, context):
    CHANNEL_ID = event.get("CHANNEL_ID")
    
    invocation_id = context.aws_request_id
    logger.set_correlation_id(invocation_id)

    # current_execution_id = logger.get_correlation_id() 
    # if not current_execution_id:
    #     current_execution_id = context.aws_request_id

    logger.info("Lambdaハンドラー処理を開始します。")

    s3 = boto3.client('s3',
                      region_name=REGION_NAME)

    # チャンネルデータの格納
    output_channel = StringIO()
    df_channel = pd.DataFrame(get_channel(CHANNEL_ID))
    df_channel.to_json(output_channel, orient='records', lines=True, force_ascii=False)
    channel_key = f'channel={CHANNEL_ID}/workflow={invocation_id}/raw_data/data_channel.json'
    s3.put_object(
        Bucket=BUCKET_NAME,
        Key=channel_key,
        Body=output_channel.getvalue()
    )
    logger.info("lambdaがS3へチャンネルデータを保存しました。", 
                extra={"bucket": BUCKET_NAME, "s3_key": channel_key})

    # ビデオデータの格納
    output_video = StringIO()
    df_videos = pd.DataFrame(get_video(CHANNEL_ID))
    df_videos.to_json(output_video, orient='records', lines=True, force_ascii=False)
    video_key = f'channel={CHANNEL_ID}/workflow={invocation_id}/raw_data/data_video.json'
    s3.put_object(
        Bucket=BUCKET_NAME,
        Key=video_key,
        Body=output_video.getvalue()
    )
    logger.info("lambdaがS3へビデオデータを保存しました。", 
                extra={"bucket": BUCKET_NAME, "s3_key": video_key})

    # コメントデータの格納
    top_videos_df = df_videos.sort_values(by='view_count', ascending=False).head(100) #本来は100

    all_comments = []
    for index, row in top_videos_df.iterrows():
        video_id = row['video_id']
        video_title = row['title']
        comments = get_comments_for_video(video_id, max_comments_per_video=100)
        all_comments.extend(comments)

    output_comment = StringIO()
    df_comments = pd.DataFrame(all_comments)
    df_comments.to_json(output_comment, orient='records', lines=True, force_ascii=False)
    comment_key = f'channel={CHANNEL_ID}/workflow={invocation_id}/raw_data/data_comment.json'
    s3.put_object(
        Bucket=BUCKET_NAME,
        Key=comment_key,
        Body=output_comment.getvalue()
    )
    logger.info("lambdaがS3へコメントデータを保存しました。", 
                extra={"bucket": BUCKET_NAME, "s3_key": comment_key})
    
    logger.info("lambdaハンドラーが完了しました。")

    return {
            "statusCode": 200,
            "bucket_name": BUCKET_NAME, 
            "input_keys": [
                f"s3://{BUCKET_NAME}/{channel_key}",
                f"s3://{BUCKET_NAME}/{video_key}",
                f"s3://{BUCKET_NAME}/{comment_key}"
            ],
            "correlation_id": invocation_id 
        }