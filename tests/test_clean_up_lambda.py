import pytest
from unittest.mock import patch, MagicMock
import json
import os
from src.clean_up.clean_up_lambda import delete_s3_prefix, lambda_handler


@patch('src.clean_up.clean_up_lambda.boto3.resource') 
def test_delete_s3_prefix_success(mock_boto_resource):
    MOCK_DELETE_RESPONSE = [
        {'Deleted': [{'Key': 'file1'}, {'Key': 'file2'}]}
    ]

    mock_filter = MagicMock()
    mock_filter.delete.return_value = MOCK_DELETE_RESPONSE
    
    mock_objects = MagicMock()
    mock_objects.filter.return_value = mock_filter
    
    mock_bucket_instance = MagicMock()
    mock_bucket_instance.objects = mock_objects
    
    mock_boto_resource.return_value.Bucket.return_value = mock_bucket_instance
    
    TEST_BUCKET = "test-processed-data-bucket"
    TEST_PREFIX = "test_artist_slug/execution-id/"

    delete_s3_prefix(TEST_BUCKET, TEST_PREFIX)

    mock_boto_resource.assert_called_once_with("s3")
    mock_boto_resource.return_value.Bucket.assert_called_once_with(TEST_BUCKET)
    mock_objects.filter.assert_called_once_with(Prefix=TEST_PREFIX)
    mock_filter.delete.assert_called_once()
