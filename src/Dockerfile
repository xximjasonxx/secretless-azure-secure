FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS base
WORKDIR /app
EXPOSE 8080

FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY ["Secretless.AzureSecureDemo.csproj", "./"]
RUN dotnet restore "Secretless.AzureSecureDemo.csproj"
COPY . .
RUN dotnet publish "Secretless.AzureSecureDemo.csproj" -c Release -o /app/publish /p:UseAppHost=false

FROM base AS final
WORKDIR /app
COPY --from=build /app/publish .
ENV ASPNETCORE_URLS=http://+:8080
ENTRYPOINT ["dotnet", "Secretless.AzureSecureDemo.dll"]
