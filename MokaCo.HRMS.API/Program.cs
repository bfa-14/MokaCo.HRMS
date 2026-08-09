using System.Text;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Authorization;
using Microsoft.IdentityModel.Tokens;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Repository.Common;
using MokaCo.HRMS.Repository.Security;
using MokaCo.HRMS.Repository.Core;
using MokaCo.HRMS.Repository.HR;
using MokaCo.HRMS.Repository.Attendance;
using MokaCo.HRMS.Repository.Report;
using MokaCo.HRMS.Repository.Workflow;
using MokaCo.HRMS.Repository.Payroll;
using MokaCo.HRMS.Services.Auth;
using MokaCo.HRMS.Services.Security;
using MokaCo.HRMS.Services.Core;
using MokaCo.HRMS.Services.HR;
using MokaCo.HRMS.Services.Attendance;
using MokaCo.HRMS.Services.Report;
using MokaCo.HRMS.Services.Workflow;
using MokaCo.HRMS.Services.Payroll;
using MokaCo.HRMS.Api.Jobs;
using Quartz;
using Scalar.AspNetCore;

var builder = WebApplication.CreateBuilder(args);

// --- Configuration ---
var connectionString = builder.Configuration.GetConnectionString("MokaCo")
    ?? throw new InvalidOperationException("Missing connection string 'MokaCo'.");

var jwtOptions = builder.Configuration.GetSection("Jwt").Get<JwtOptions>()
    ?? throw new InvalidOperationException("Missing 'Jwt' configuration.");

// --- DI: infrastructure ---
builder.Services.AddSingleton<IDbConnectionFactory>(new SqlConnectionFactory(connectionString));
builder.Services.AddSingleton(jwtOptions);

// --- DI: repositories (Security) ---
builder.Services.AddScoped<IUserRepository, UserRepository>();
builder.Services.AddScoped<IUserSignatureRepository, UserSignatureRepository>();
builder.Services.AddScoped<IRoleRepository, RoleRepository>();
builder.Services.AddScoped<IPermissionRepository, PermissionRepository>();
builder.Services.AddScoped<IRefreshTokenRepository, RefreshTokenRepository>();

// --- DI: repositories (Core) ---
builder.Services.AddScoped<ICurrencyRepository, CurrencyRepository>();
builder.Services.AddScoped<IExchangeRateRepository, ExchangeRateRepository>();
builder.Services.AddScoped<IDashboardRepository, DashboardRepository>();

// --- DI: repositories (HR) ---
builder.Services.AddScoped<IBranchRepository, BranchRepository>();
builder.Services.AddScoped<IDepartmentRepository, DepartmentRepository>();
builder.Services.AddScoped<IPositionRepository, PositionRepository>();
builder.Services.AddScoped<IComponentTypeRepository, ComponentTypeRepository>();
builder.Services.AddScoped<IEmployeeRepository, EmployeeRepository>();
builder.Services.AddScoped<ILeaveTypeRepository, LeaveTypeRepository>();
builder.Services.AddScoped<ISalaryComponentRepository, SalaryComponentRepository>();
builder.Services.AddScoped<IDocumentRepository, DocumentRepository>();
builder.Services.AddScoped<ILeaveLedgerRepository, LeaveLedgerRepository>();
builder.Services.AddScoped<ILeaveAccrualRepository, LeaveAccrualRepository>();

// --- DI: repositories (Attendance) ---
builder.Services.AddScoped<ISettingRepository, SettingRepository>();
builder.Services.AddScoped<ISystemRepository, SystemRepository>();
builder.Services.AddScoped<IDeviceRepository, DeviceRepository>();
builder.Services.AddScoped<IShiftRepository, ShiftRepository>();
builder.Services.AddScoped<IRosterRepository, RosterRepository>();
builder.Services.AddScoped<IIngestionRepository, IngestionRepository>();
builder.Services.AddScoped<IAttendanceRepository, AttendanceRepository>();
builder.Services.AddScoped<ICorrectionRepository, CorrectionRepository>();

// --- DI: repositories (Report) ---
builder.Services.AddScoped<IReportRepository, ReportRepository>();

// --- DI: repositories (Workflow) ---
builder.Services.AddScoped<IDefinitionRepository, DefinitionRepository>();
builder.Services.AddScoped<IRequestRepository, RequestRepository>();
builder.Services.AddScoped<IAttachmentRepository, AttachmentRepository>();
builder.Services.AddScoped<IExitPermissionRepository, ExitPermissionRepository>();
builder.Services.AddScoped<ILeaveRequestRepository, LeaveRequestRepository>();
builder.Services.AddScoped<ITipDistributionRepository, TipDistributionRepository>();
builder.Services.AddScoped<IShiftSwapRepository, ShiftSwapRepository>();
builder.Services.AddScoped<IOvertimeRepository, OvertimeRepository>();
builder.Services.AddScoped<IExpenseRepository, ExpenseRepository>();
builder.Services.AddScoped<IAvailabilityRepository, AvailabilityRepository>();
builder.Services.AddScoped<IOnboardingRepository, OnboardingRepository>();
builder.Services.AddScoped<ISeparationRepository, SeparationRepository>();
builder.Services.AddScoped<IPayrollAdjustmentRepository, PayrollAdjustmentRepository>();
builder.Services.AddScoped<IWorkflowSupportRepository, WorkflowSupportRepository>();

// --- DI: repositories (Payroll) ---
builder.Services.AddScoped<IPayrollRepository, PayrollRepository>();

// --- DI: services (Security) ---
builder.Services.AddSingleton<IPasswordHasher, Argon2PasswordHasher>();
builder.Services.AddSingleton<IJwtTokenService, JwtTokenService>();
builder.Services.AddScoped<IAuthService, AuthService>();
builder.Services.AddScoped<IUserService, UserService>();
builder.Services.AddScoped<IUserSignatureService, UserSignatureService>();

// --- DI: services (Core) ---
builder.Services.AddScoped<ICurrencyService, CurrencyService>();
builder.Services.AddScoped<IExchangeRateService, ExchangeRateService>();
builder.Services.AddScoped<IDashboardService, DashboardService>();

// --- DI: services (HR) ---
builder.Services.AddScoped<IBranchService, BranchService>();
builder.Services.AddScoped<IDepartmentService, DepartmentService>();
builder.Services.AddScoped<IPositionService, PositionService>();
builder.Services.AddScoped<IComponentTypeService, ComponentTypeService>();
builder.Services.AddScoped<IEmployeeService, EmployeeService>();
builder.Services.AddScoped<ILeaveTypeService, LeaveTypeService>();
builder.Services.AddScoped<ISalaryComponentService, SalaryComponentService>();
builder.Services.AddScoped<IDocumentService, DocumentService>();
builder.Services.AddScoped<ILeaveLedgerService, LeaveLedgerService>();
builder.Services.AddScoped<ILeaveAccrualService, LeaveAccrualService>();

// --- DI: services (Attendance) ---
builder.Services.AddScoped<ISettingService, SettingService>();
builder.Services.AddScoped<IDeviceService, DeviceService>();
builder.Services.AddScoped<IShiftService, ShiftService>();
builder.Services.AddScoped<IRosterService, RosterService>();
builder.Services.AddScoped<IImportService, ImportService>();
builder.Services.AddScoped<IAttendanceService, AttendanceService>();
builder.Services.AddScoped<ICorrectionService, CorrectionService>();

// --- DI: services (Report) ---
builder.Services.AddScoped<IReportService, ReportService>();

// --- DI: services (Workflow) ---
builder.Services.AddScoped<IDefinitionService, DefinitionService>();
builder.Services.AddScoped<IRequestService, RequestService>();
builder.Services.AddScoped<IAttachmentService, AttachmentService>();
builder.Services.AddScoped<IExitPermissionService, ExitPermissionService>();
builder.Services.AddScoped<ILeaveRequestService, LeaveRequestService>();
builder.Services.AddScoped<IDecisionSignatureService, DecisionSignatureService>();
builder.Services.AddScoped<ITipDistributionService, TipDistributionService>();
builder.Services.AddScoped<IShiftSwapService, ShiftSwapService>();
builder.Services.AddScoped<IOvertimeService, OvertimeService>();
builder.Services.AddScoped<IExpenseService, ExpenseService>();
builder.Services.AddScoped<IAvailabilityService, AvailabilityService>();
builder.Services.AddScoped<IOnboardingService, OnboardingService>();
builder.Services.AddScoped<ISeparationService, SeparationService>();
builder.Services.AddScoped<IPayrollAdjustmentService, PayrollAdjustmentService>();
builder.Services.AddScoped<IWorkflowSupportService, WorkflowSupportService>();

// --- DI: services (Payroll) ---
builder.Services.AddScoped<IPayrollService, PayrollService>();

// --- Scheduled jobs (Quartz.NET, in-memory RAMJobStore — no DB job store) ---
builder.Services.AddQuartz(q =>
{
    var accrualJobKey = new JobKey("MonthlyAccrualJob");
    q.AddJob<MonthlyAccrualJob>(opts => opts.WithIdentity(accrualJobKey));
    q.AddTrigger(t => t
        .ForJob(accrualJobKey)
        .WithIdentity("MonthlyAccrualTrigger")
        // seconds-first cron: 00:30 on day 1 of every month
        .WithCronSchedule("0 30 0 1 * ?"));

    // Attendance: process punches, mark absentees, reclassify approved leave.
    // The store is in-memory, so a run missed while the API was down is LOST, not caught up —
    // which is why /api/attendance/process and /mark-absentees are also exposed manually.
    var nightlyAttendanceJobKey = new JobKey("NightlyAttendanceJob");
    q.AddJob<NightlyAttendanceJob>(opts => opts.WithIdentity(nightlyAttendanceJobKey));
    q.AddTrigger(t => t
        .ForJob(nightlyAttendanceJobKey)
        .WithIdentity("NightlyAttendanceTrigger")
        // seconds-first cron: 01:00 every day
        .WithCronSchedule("0 0 1 * * ?"));
});
builder.Services.AddQuartzHostedService(opts => opts.WaitForJobsToComplete = true);

// --- Authentication (JWT) ---
builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidateAudience = true,
            ValidateLifetime = true,
            ValidateIssuerSigningKey = true,
            ValidIssuer = jwtOptions.Issuer,
            ValidAudience = jwtOptions.Audience,
            IssuerSigningKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(jwtOptions.SecretKey)),
            ClockSkew = TimeSpan.FromSeconds(30)
        };
    });

// --- Authorization (permission policies) ---
builder.Services.AddSingleton<IAuthorizationPolicyProvider, PermissionPolicyProvider>();
builder.Services.AddAuthorization();

// --- CORS for the React front end (adjust origin) ---
const string CorsPolicy = "MokaCoFront";
builder.Services.AddCors(o => o.AddPolicy(CorsPolicy, p =>
    p.WithOrigins("http://localhost:5173")   // Vite dev server; change as needed
     .AllowAnyHeader()
     .AllowAnyMethod()));

builder.Services.AddControllers();
builder.Services.AddOpenApi();

var app = builder.Build();

if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();          // serves the spec at /openapi/v1.json
    app.MapScalarApiReference(); // interactive UI at /scalar/v1
}

app.UseHttpsRedirection();
app.UseCors(CorsPolicy);
app.UseAuthentication();
app.UseAuthorization();
app.MapControllers();

app.Run();
