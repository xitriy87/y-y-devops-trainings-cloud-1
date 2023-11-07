FROM golang:1.21
RUN useradd -u 1000 -d /usr/src/app test
USER test
WORKDIR /usr/src/app
COPY . .
RUN go mod download && CGO_ENABLED=0 go build -o ./catgpt
EXPOSE 8080
EXPOSE 9090
ENTRYPOINT ["./catgpt"]
