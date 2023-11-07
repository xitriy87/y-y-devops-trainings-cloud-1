FROM golang:1.21 as build
WORKDIR /usr/src/app
COPY . .
RUN go mod download && CGO_ENABLED=0 go build -o ./catgpt

FROM gcr.io/distroless/static-debian12:latest-amd64
WORKDIR /app
COPY --from=build /usr/src/app/catgpt .
EXPOSE 8080
EXPOSE 9090
ENTRYPOINT ["./catgpt"]
