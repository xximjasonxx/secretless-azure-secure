FROM mcr.microsoft.com/dotnet/sdk:8.0-bookworm-slim AS build
WORKDIR /src
COPY AssetService.csproj .
RUN dotnet restore
COPY . .
RUN dotnet publish -c Release -o /app/publish /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:8.0-bookworm-slim AS final
WORKDIR /app
RUN mkdir -p /data && chown -R $APP_UID:$APP_UID /data
COPY --from=build /app/publish .
ENV ASPNETCORE_URLS=http://+:8080
ENV SQLITE_PATH=/data/assets.db
EXPOSE 8080
USER $APP_UID
ENTRYPOINT ["dotnet", "AssetService.dll"]
