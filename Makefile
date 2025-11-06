run-container:
	docker container run -it --rm \
		--dns 8.8.8.8 \
		-v $(PWD):/app \
		-v ~/.aws:/root/.aws:ro \
		-v ~/.config/gcloud:/root/.config/gcloud:ro \
		--name terraform-session \
		terraform-aws-env:v1.0 bash

run-container-test:
	docker container run -it --rm -v "$(PWD)":/app youtube_ci_test:v2.0 /bin/bash