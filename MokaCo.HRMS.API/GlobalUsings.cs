// [LiveTopics] sits at the top of every controller whose writes should wake subscribed pages, so
// the namespace is imported globally rather than repeated in seventeen files. Declaring it here
// also means a new controller gets the attribute available without a using line to forget.
global using MokaCo.HRMS.Api.Hubs;
