run-container:
	docker container run -it --rm \
		--dns 8.8.8.8 \
		-v $(PWD):/app \
		-v ~/.aws:/root/.aws:ro \
		--name terraform-session \
		terraform-aws-env:v1.0 bash