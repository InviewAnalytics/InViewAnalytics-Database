USE [master]
GO
/****** Object:  Database [inviewanalytics]    Script Date: 6/20/2019 10:23:04 AM ******/
CREATE DATABASE [inviewanalytics]
 CONTAINMENT = NONE
 ON  PRIMARY 
( NAME = N'inviewanalytics', FILENAME = N'C:\Program Files\Microsoft SQL Server\MSSQL12.MSSQLSERVER\MSSQL\DATA\inviewanalytics.mdf' , SIZE = 772096KB , MAXSIZE = UNLIMITED, FILEGROWTH = 1024KB )
 LOG ON 
( NAME = N'inviewanalytics_log', FILENAME = N'C:\Program Files\Microsoft SQL Server\MSSQL12.MSSQLSERVER\MSSQL\DATA\inviewanalytics_log.ldf' , SIZE = 219264KB , MAXSIZE = 2048GB , FILEGROWTH = 10%)
GO
IF (1 = FULLTEXTSERVICEPROPERTY('IsFullTextInstalled'))
begin
EXEC [inviewanalytics].[dbo].[sp_fulltext_database] @action = 'enable'
end
GO
ALTER DATABASE [inviewanalytics] SET ANSI_NULL_DEFAULT OFF 
GO
ALTER DATABASE [inviewanalytics] SET ANSI_NULLS OFF 
GO
ALTER DATABASE [inviewanalytics] SET ANSI_PADDING OFF 
GO
ALTER DATABASE [inviewanalytics] SET ANSI_WARNINGS OFF 
GO
ALTER DATABASE [inviewanalytics] SET ARITHABORT OFF 
GO
ALTER DATABASE [inviewanalytics] SET AUTO_CLOSE OFF 
GO
ALTER DATABASE [inviewanalytics] SET AUTO_CREATE_STATISTICS ON 
GO
ALTER DATABASE [inviewanalytics] SET AUTO_SHRINK OFF 
GO
ALTER DATABASE [inviewanalytics] SET AUTO_UPDATE_STATISTICS ON 
GO
ALTER DATABASE [inviewanalytics] SET CURSOR_CLOSE_ON_COMMIT OFF 
GO
ALTER DATABASE [inviewanalytics] SET CURSOR_DEFAULT  GLOBAL 
GO
ALTER DATABASE [inviewanalytics] SET CONCAT_NULL_YIELDS_NULL OFF 
GO
ALTER DATABASE [inviewanalytics] SET NUMERIC_ROUNDABORT OFF 
GO
ALTER DATABASE [inviewanalytics] SET QUOTED_IDENTIFIER OFF 
GO
ALTER DATABASE [inviewanalytics] SET RECURSIVE_TRIGGERS OFF 
GO
ALTER DATABASE [inviewanalytics] SET  DISABLE_BROKER 
GO
ALTER DATABASE [inviewanalytics] SET AUTO_UPDATE_STATISTICS_ASYNC OFF 
GO
ALTER DATABASE [inviewanalytics] SET DATE_CORRELATION_OPTIMIZATION OFF 
GO
ALTER DATABASE [inviewanalytics] SET TRUSTWORTHY OFF 
GO
ALTER DATABASE [inviewanalytics] SET ALLOW_SNAPSHOT_ISOLATION OFF 
GO
ALTER DATABASE [inviewanalytics] SET PARAMETERIZATION SIMPLE 
GO
ALTER DATABASE [inviewanalytics] SET READ_COMMITTED_SNAPSHOT OFF 
GO
ALTER DATABASE [inviewanalytics] SET HONOR_BROKER_PRIORITY OFF 
GO
ALTER DATABASE [inviewanalytics] SET RECOVERY SIMPLE 
GO
ALTER DATABASE [inviewanalytics] SET  MULTI_USER 
GO
ALTER DATABASE [inviewanalytics] SET PAGE_VERIFY CHECKSUM  
GO
ALTER DATABASE [inviewanalytics] SET DB_CHAINING OFF 
GO
ALTER DATABASE [inviewanalytics] SET FILESTREAM( NON_TRANSACTED_ACCESS = OFF ) 
GO
ALTER DATABASE [inviewanalytics] SET TARGET_RECOVERY_TIME = 0 SECONDS 
GO
USE [inviewanalytics]
GO
/****** Object:  User [inviewanalytics]    Script Date: 6/20/2019 10:23:06 AM ******/
CREATE USER [inviewanalytics] FOR LOGIN [inviewanalytics] WITH DEFAULT_SCHEMA=[dbo]
GO
ALTER ROLE [db_owner] ADD MEMBER [inviewanalytics]
GO
/****** Object:  StoredProcedure [dbo].[Addshipmentorder_toinventory]    Script Date: 6/20/2019 10:23:07 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Sagar Sharma
-- Create date: 12-July-2018
-- Description: SP to INSERT the inventory after receiving the drug from other store shippment.
-- EXEC Addshipmentorder_toinventory 16
-- =============================================

CREATE PROCEDURE [dbo].[Addshipmentorder_toinventory]
	(
	@shippmentId			int,
	@pharmacyId             int
	)
 AS 
BEGIN 
	CREATE TABLE #temp_inventory_rec(
        pharmacy_id   INT,
		ndc BIGINT,
		drug_name NVARCHAR(2000),
		quantity  DECIMAL(10,2),
		price     MONEY,
		pack_size DECIMAL(10,2),
		strength NVARCHAR(100),
		created_on DATETIME
		)

		-- insert all the ndc that need to be added in inventory from shippment details table.
		INSERT INTO #temp_inventory_rec (pharmacy_id,ndc, quantity, price, created_on)
 		select 
			ship.purchaser_pharmacy_id,
			shipDetails.ndc,
			shipDetails.quantity, 
			shipDetails.unit_price, 
			DATEADD(month, -9, ISNULL(shipDetails.exipry_date, DATEADD(month,9,GETDATE()))) 
			from shippment ship
			INNER JOIN shippmentdetails shipDetails ON ship.shippment_id = shipDetails.shippment_id
			where ship.shippment_id = @shippmentId

		-- update the pack_size and strength from edi_inventory table.
		UPDATE temp_inv_rec
			SET temp_inv_rec.pack_size = (CAST(ISNULL(E.[PO4_Pack_FDBSize],0.0) AS Decimal(10,2)) * CAST(ISNULL(E.[PO4_Pack_MetricSize],0.0) AS DECIMAL(10,2))),
			temp_inv_rec.strength = ISNULL(E.PID_Strength,'')
			FROM #temp_inventory_rec temp_inv_rec
			INNER JOIN edi_inventory E
			ON temp_inv_rec.ndc = TRY_PARSE(E.LIN_NDC AS BIGINT) 

		-- update the drug name form FDA table.
		UPDATE temp_inv
			SET temp_inv.drug_name = fdb_prd.NONPROPRIETARYNAME 
			FROM #temp_inventory_rec temp_inv 
			INNER JOIN  [dbo].[FDB_Package] fdb_pkg		
			ON fdb_pkg.NDCINT = temp_inv.ndc
			INNER JOIN [dbo].[FDB_Product] fdb_prd ON fdb_prd.PRODUCTID =  fdb_pkg.PRODUCTID


		-- Insert the drugs into inventory table (drug purchase from market place )
		INSERT INTO inventory (pharmacy_id, drug_name, ndc, pack_size, price, NDC_Packsize, Strength, created_on, is_deleted)
			SELECT pharmacy_id,drug_name, ndc, quantity, price, pack_size, strength, created_on,0    
			FROM #temp_inventory_rec

	

           /*BEGIN : Added to substract sold quantity from Inventory of seller. */
			DECLARE @pack_size  DECIMAL(10,2);
			DECLARE @ndc BIGINT;
			SELECT @pack_size = quantity,
			@ndc = ndc FROM #temp_inventory_rec
	
	WHILE(@pack_size > 0)
		BEGIN

			 DECLARE @QOH  DECIMAL(10,2);
			 DECLARE @inventory_id  INT;

			SELECT  @QOH = inv_b.pack_size, @inventory_id = inv_b.inventory_id  from inventory inv_b WHERE inv_b.inventory_id =

			 (SELECT TOP 1 MIN(inv_a.inventory_id) FROM inventory inv_a WHERE inv_a.ndc = @ndc AND inv_a.pharmacy_id = @pharmacyId AND inv_a.pack_size >0 AND inv_a.is_deleted = 0 ) 

				IF((@pack_size >= @QOH) AND (@QOH > 0) )
					BEGIN
						Update inventory SET pack_size = 0,  is_deleted = 1 WHERE inventory_id = @inventory_id and pharmacy_id = @pharmacyId
						SET @pack_size = @pack_size-@QOH;

					END		  
					ELSE
					BEGIN
						Update inventory SET pack_size = (@QOH-@pack_size) WHERE inventory_id = @inventory_id and pharmacy_id = @pharmacyId
						SET @pack_size = @pack_size-@QOH;
					END

		  			
		            

          END
		/*END Added to substract sold quantity from Inventory of seller */
		DROP TABLE #temp_inventory_rec

		-- Mark the shipped order as received in shippment table.
		UPDATE shippment set 
			order_received = 1
			WHERE shippment_id = @shippmentId
			


END;




GO
/****** Object:  StoredProcedure [dbo].[Addshipmentorder_toinventory_bk_29_03_2019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Sagar Sharma
-- Create date: 12-July-2018
-- Description: SP to INSERT the inventory after receiving the drug from other store shippment.
-- EXEC Addshipmentorder_toinventory 16
-- =============================================

CREATE PROCEDURE [dbo].[Addshipmentorder_toinventory_bk_29_03_2019]
	(
	@shippmentId			int
	)
 AS 
 BEGIN
		 CREATE TABLE #temp_inventory_rec(
        pharmacy_id   INT,
		ndc BIGINT,
		drug_name NVARCHAR(2000),
		quantity  DECIMAL(10,2),
		price     MONEY,
		pack_size DECIMAL(10,2),
		strength NVARCHAR(100),
		created_on DATETIME
		)

		-- insert all the ndc that need to be added in inventory from shippment details table.
		INSERT INTO #temp_inventory_rec (pharmacy_id,ndc, quantity, price, created_on)
 		select 
			ship.purchaser_pharmacy_id,
			shipDetails.ndc,
			shipDetails.quantity, 
			shipDetails.unit_price, 
			DATEADD(month, -9, ISNULL(shipDetails.exipry_date, DATEADD(month,9,GETDATE()))) 
			from shippment ship
			INNER JOIN shippmentdetails shipDetails ON ship.shippment_id = shipDetails.shippment_id
			where ship.shippment_id = @shippmentId

		-- update the pack_size and strength from edi_inventory table.
		UPDATE temp_inv_rec
			SET temp_inv_rec.pack_size = (CAST(ISNULL(E.[PO4_Pack_FDBSize],0.0) AS Decimal(10,2)) * CAST(ISNULL(E.[PO4_Pack_MetricSize],0.0) AS DECIMAL(10,2))),
			temp_inv_rec.strength = ISNULL(E.PID_Strength,'')
			FROM #temp_inventory_rec temp_inv_rec
			INNER JOIN edi_inventory E
			ON temp_inv_rec.ndc = TRY_PARSE(E.LIN_NDC AS BIGINT) 

		-- update the drug name form FDA table.
		UPDATE temp_inv
			SET temp_inv.drug_name = fdb_prd.NONPROPRIETARYNAME 
			FROM #temp_inventory_rec temp_inv 
			INNER JOIN  [dbo].[FDB_Package] fdb_pkg		
			ON fdb_pkg.NDCINT = temp_inv.ndc
			INNER JOIN [dbo].[FDB_Product] fdb_prd ON fdb_prd.PRODUCTID =  fdb_pkg.PRODUCTID


		-- Insert the drugs into inventory table (drug purchase from market place )
		INSERT INTO inventory (pharmacy_id, drug_name, ndc, pack_size, price, NDC_Packsize, Strength, created_on, is_deleted)
			SELECT pharmacy_id,drug_name, ndc, quantity, price, pack_size, strength, created_on,0    
			FROM #temp_inventory_rec


		DROP TABLE #temp_inventory_rec

		-- Mark the shipped order as received in shippment table.
		UPDATE shippment set 
			order_received = 1
			WHERE shippment_id = @shippmentId
			


END;





GO
/****** Object:  StoredProcedure [dbo].[CreateShippment]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[CreateShippment]  
(     
 @seller_pharmacy_id  INTEGER   
)    
AS   
BEGIN   
  
 DECLARE @SHIPMENT_PRE_PREPARED INT  
 DECLARE @SHIPMENT_PREPARED INT  
  
 SET @SHIPMENT_PRE_PREPARED  = 1  
 SET @SHIPMENT_PREPARED = 2  
  
 CREATE TABLE #temp_Shipment_lineitems(  
  rowID INT IDENTITY(1,1) NOT NULL,  
  pre_shippmentorder_id INT,  
  mp_postitem_id INT,  
  ndc_code BIGINT,  
  sales_price DECIMAL(10,2),  
  lot_number NVARCHAR(500),  
  exipry_date DATETIME,  
  quantity DECIMAL(10,2),  
  purchaser_pharmacy_id INT,  
  seller_pharmacy_id INT,  
  drug_name  NVARCHAR(2000),  
  shipping_method_id INT,  /*added for shipping method*/  
  strength NVARCHAR(1000) , 
  pack_size DECIMAL(18,2)  /*Added for Manual Invoice */
        
 )  
  
 INSERT INTO #temp_Shipment_lineitems(pre_shippmentorder_id, mp_postitem_id, ndc_code, sales_price, lot_number, exipry_date, quantity, purchaser_pharmacy_id, seller_pharmacy_id,drug_name,shipping_method_id,strength,pack_size)(  
  SELECT   
    pso.pre_shippmentorder_id,  
    mpi.mp_postitem_id,  
    mpi.ndc_code,  
    mpi.sales_price,  
    mpi.lot_number,  
    mpi.exipry_date,  
    pso.quantity,  
    pso.purchaser_pharmacy_id,  
    pso.seller_pharmacy_id,  
    CONCAT(mpi.drug_name, mpi.strength),  
    pso.shipping_method_id ,
	mpi.strength,
	mpi.pack_size 	          /*added for shipping method*/  
  FROM pre_shippmentorder pso  
   INNER JOIN mp_post_items mpi ON pso.mp_postitem_id = mpi.mp_postitem_id  
   --INNER JOIN ShippingMethods sm ON pso.shippingmethodId = sm.ShippingMethodID  
     WHERE ((seller_pharmacy_id = @seller_pharmacy_id) AND   
      (shipping_status_master_id = @SHIPMENT_PRE_PREPARED))        
 )  
  
   
 CREATE TABLE #temp_Shipments(    
  rowID INT IDENTITY(1,1) NOT NULL,  
  purchaser_pharmacy_id INT,    
  shipping_method_id INT    /*added for shipping method*/  
 )  
 INSERT INTO #temp_Shipments(purchaser_pharmacy_id,shipping_method_id)(  
  SELECT purchaser_pharmacy_id, shipping_method_id FROM #temp_Shipment_lineitems GROUP BY purchaser_pharmacy_id,shipping_method_id  
 )  
  
  
 DECLARE @index INT = 1;  
 DECLARE @count INT  
  
 SELECT @count = count (*) FROM #temp_Shipments;  
 WHILE (@index <= @count)  
 BEGIN  
   
  DECLARE @newShippmentID INT  
  DECLARE @purchaser_pharmacy_id INT  
  DECLARE @shipping_method_Id  INT  
  
  SELECT @purchaser_pharmacy_id = purchaser_pharmacy_id,  
         @shipping_method_Id = shipping_method_id    /*added for shipping method*/  
   FROM #temp_Shipments WHERE  rowID = @index   
  
  
   BEGIN  
   INSERT INTO shippment(  
     purchaser_pharmacy_id  
     ,shipping_method_id         /*added for shipping method*/  
     ,seller_pharmacy_id  
     ,shipping_status_master_id  
     ,created_by  
     ,created_on  
     ,is_deletd  
     )      
  
     --(SELECT DISTINCT @purchaser_pharmacy_id,@shipping_method_Id, @seller_pharmacy_id, @SHIPMENT_PREPARED, @seller_pharmacy_id,GETDATE(),0  
     -- FROM #temp_Shipment_lineitems    
     -- WHERE purchaser_pharmacy_id = @purchaser_pharmacy_id AND shipping_method_id = @shipping_method_Id)  
     
    VALUES (  
     @purchaser_pharmacy_id,@shipping_method_Id, @seller_pharmacy_id, @SHIPMENT_PREPARED, @seller_pharmacy_id,GETDATE(),0)  
   END  
  
  SET @newShippmentID = @@IDENTITY   
  
  INSERT INTO shippmentdetails (  
   [shippment_id]  
   ,[ndc]  
   ,[quantity]  
   ,[unit_price]  
   ,[exipry_date]  
   ,[lot_number]  
   ,[drug_name]  
   ,[pack_size]
   ,[strength]   /*Added for Manual Invoice */
   )  
   (  
    SELECT @newShippmentID, ndc_code,quantity, sales_price, exipry_date,lot_number, drug_name  ,ISNULL(pack_size,0), ISNULL(strength,0)  /*Added for Manual Invoice */
    FROM #temp_Shipment_lineitems   
    WHERE purchaser_pharmacy_id = @purchaser_pharmacy_id  
     AND shipping_method_id  = @shipping_method_Id  
       
   )  
  
  SET @index = @index + 1  
  
 END  
  
 -- update the status of all preprepared orders to prepared in pre_shippment table.  
 UPDATE pre_so  
  SET pre_so.shipping_status_master_id = @SHIPMENT_PREPARED  
 FROM pre_shippmentorder pre_so    
 INNER JOIN #temp_Shipment_lineitems tlsi ON  
  pre_so.pre_shippmentorder_id = tlsi.pre_shippmentorder_id  
  
  
 DROP TABLE #temp_Shipments  
 DROP TABLE #temp_Shipment_lineitems  
  
END  
GO
/****** Object:  StoredProcedure [dbo].[CreateShippment_bk_05/02/2019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


--exec CreateShippment 1417
CREATE PROCEDURE [dbo].[CreateShippment_bk_05/02/2019]
(  
	@seller_pharmacy_id		INTEGER
	
)  
AS 
BEGIN	

	DECLARE @SHIPMENT_PRE_PREPARED INT
	DECLARE @SHIPMENT_PREPARED INT

	SET @SHIPMENT_PRE_PREPARED  = 1
	SET @SHIPMENT_PREPARED = 2

	--SELECT * FROM pre_shippmentorder
	CREATE TABLE #temp_Shipment_lineitems(
		rowID	INT IDENTITY(1,1)	NOT NULL,
		pre_shippmentorder_id INT,
		mp_postitem_id INT,
		ndc_code BIGINT,
		sales_price DECIMAL(10,2),
		lot_number NVARCHAR(500),
		exipry_date DATETIME,
		quantity DECIMAL(10,2),
		purchaser_pharmacy_id INT,
		seller_pharmacy_id INT,
		drug_name  NVARCHAR(2000)
						
	)

	INSERT INTO #temp_Shipment_lineitems(pre_shippmentorder_id, mp_postitem_id, ndc_code, sales_price, lot_number, exipry_date, quantity, purchaser_pharmacy_id, seller_pharmacy_id,drug_name )(
		SELECT 
			 pso.pre_shippmentorder_id,
			 mpi.mp_postitem_id,
			 mpi.ndc_code,
			 mpi.sales_price,
			 mpi.lot_number,
			 mpi.exipry_date,
			 pso.quantity,
			 pso.purchaser_pharmacy_id,
			 pso.seller_pharmacy_id,
			 CONCAT(mpi.drug_name, mpi.strength)
		FROM pre_shippmentorder pso
			INNER JOIN mp_post_items mpi ON pso.mp_postitem_id = mpi.mp_postitem_id
					WHERE ((seller_pharmacy_id = @seller_pharmacy_id) AND 
						(shipping_status_master_id = @SHIPMENT_PRE_PREPARED))
	)

	
	CREATE TABLE #temp_Shipments(		
		rowID	INT IDENTITY(1,1)	NOT NULL,
		purchaser_pharmacy_id INT		
	)
	INSERT INTO #temp_Shipments(purchaser_pharmacy_id)(
		SELECT purchaser_pharmacy_id FROM #temp_Shipment_lineitems GROUP BY purchaser_pharmacy_id
	)


	DECLARE @index INT = 1;
	DECLARE @count INT

	SELECT @count = count (*) FROM #temp_Shipments;

	WHILE (@index <= @count)
	BEGIN
		DECLARE @newShippmentID INT
		DECLARE @purchaser_pharmacy_id INT
		
		SELECT @purchaser_pharmacy_id = purchaser_pharmacy_id
			FROM #temp_Shipments WHERE  rowID = @index 


		INSERT INTO shippment(
			purchaser_pharmacy_id
			,seller_pharmacy_id
			,shipping_status_master_id
			,created_by
			,created_on
			,is_deletd
		)VALUES (
			@purchaser_pharmacy_id, @seller_pharmacy_id, @SHIPMENT_PREPARED, @seller_pharmacy_id,GETDATE(),0)

		SET @newShippmentID = @@IDENTITY 

		INSERT INTO shippmentdetails (
			[shippment_id]
			,[ndc]
			,[quantity]
			,[unit_price]
			,[exipry_date]
			,[lot_number]
			,[drug_name]	
			)
			(
				SELECT @newShippmentID, ndc_code,quantity, sales_price, exipry_date,lot_number, drug_name 
				FROM #temp_Shipment_lineitems 
				WHERE purchaser_pharmacy_id = @purchaser_pharmacy_id
			)

		SET @index = @index + 1

	END

	-- update the status of all preprepared orders to prepared in pre_shippment table.
	UPDATE pre_so
		SET pre_so.shipping_status_master_id = @SHIPMENT_PREPARED
	FROM pre_shippmentorder pre_so		
	INNER JOIN #temp_Shipment_lineitems tlsi ON
		pre_so.pre_shippmentorder_id = tlsi.pre_shippmentorder_id


	DROP TABLE #temp_Shipments
	DROP TABLE #temp_Shipment_lineitems

END

GO
/****** Object:  StoredProcedure [dbo].[Get_PharmacyOwner_ById]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[Get_PharmacyOwner_ById]
	(
	@id int
	)
	AS 
	BEGIN
		Select * from sa_pharmacy_owner AS P JOIN sa_superAdmin_sddress AS A ON
		P.pharmacy_owner_id=A.pharmacy_Owner_id
		WHERE P.pharmacy_owner_id=@id AND (P.is_deleted <=0 OR P.is_deleted IS NULL)		
	END




GO
/****** Object:  StoredProcedure [dbo].[GetDrugnameFromFDA]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
--=======================================================
-- Auther Name : Sagar Sharma
-- Created On : 22-06-2018
-- SP to get the drug name from FDA by ndc code

--=======================================================

CREATE PROCEDURE [dbo].[GetDrugnameFromFDA]
(  
	@ndc		BIGINT
)
AS 

BEGIN	
		SELECT top 1
			fdb_pro.NONPROPRIETARYNAME
		FROM FDB_Package fdb_pack 

		INNER JOIN FDB_Product fdb_pro ON fdb_pack.PRODUCTNDC = fdb_pro.PRODUCTNDC
		WHERE fdb_pack.NDCINT =  @ndc
END

GO
/****** Object:  StoredProcedure [dbo].[MonthlyInventorySummary]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Create date: <Create Date, 2018-05-29>
-- Description:	<Description, stored procedure to get Inventory summary according to Month>
--MonthlyInventorySummary 1
-- =============================================

CREATE PROC [dbo].[MonthlyInventorySummary]
(
@pharmacyId    INT
)
AS 
BEGIN

	DECLARE @START_DATE DATETIME
	DECLARE @END_DATE DATETIME
	SET NOCOUNT ON;

	-- GET START & END DATE OF MONTH
	SET  @START_DATE =  (SELECT DATEADD(yy, DATEDIFF(yy, 0, GETDATE()), 0)) 
	SET  @END_DATE = (select DATEADD (dd, -1, DATEADD(yy, DATEDIFF(yy, 0, GETDATE()) +1, 0))) 
	
	-- Get price and created date from inventory table
	SELECT price as Price,created_on AS Created_on,DATENAME(month,created_on) as monthsname
	 INTO #Temp_MonthlyInventorySummary	FROM inventory
	WHERE ((is_deleted = 0)	AND 
	        (pharmacy_id= @pharmacyId ) AND 
			(created_on BETWEEN @START_DATE AND @END_DATE)
			)

		;WITH months(MonthNumber) AS
		(
			SELECT 0
			UNION ALL
			SELECT MonthNumber + 1 
			FROM months
			WHERE MonthNumber < 11
		)
		
		select LEFT(DATENAME(MONTH,DATEADD(MONTH,c.MonthNumber,'2012-01-01 06:35:59.157')),3) AS WeekMonth,IsNull(Aggr1.price,0) AS Price 
		from
		(SELECT
		      IsNull(SUM( temp.Price ),0)  AS Price,
			  MONTH(temp.created_on) MonthNo			  
			  FROM #Temp_MonthlyInventorySummary temp  				
			  GROUP BY MONTH(created_on)) 
			  Aggr1 right outer JOIN months c on Aggr1.MonthNo-1 =c.MonthNumber	
			  order by c.MonthNumber--Sort By Ascending			
END


GO
/****** Object:  StoredProcedure [dbo].[MonthlyInventorySummary1]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Create date: <Create Date, 2018-05-29>
-- Description:	<Description, stored procedure to get Inventory summary according to Month>
--MonthlyInventorySummary 1
-- =============================================

CREATE PROC [dbo].[MonthlyInventorySummary1]
(
@pharmacyId    INT
)
AS 
BEGIN

	DECLARE @START_DATE DATETIME
	DECLARE @END_DATE DATETIME
	SET NOCOUNT ON;

	-- GET START & END DATE OF MONTH
	SET  @START_DATE =  (SELECT DATEADD(yy, DATEDIFF(yy, 0, GETDATE()), 0)) 
	SET  @END_DATE = (select DATEADD (dd, -1, DATEADD(yy, DATEDIFF(yy, 0, GETDATE()) +1, 0))) 
	
	-- Get price and created date from inventory table
	SELECT price as Price,created_on AS Created_on,DATENAME(month,created_on) as monthsname
	 INTO #Temp_MonthlyInventorySummary	FROM inventory
	WHERE ((is_deleted = 0)	AND 
	        (pharmacy_id= @pharmacyId ) AND 
			(created_on BETWEEN @START_DATE AND @END_DATE)
			)

		;WITH months(MonthNumber) AS
		(
			SELECT 0
			UNION ALL
			SELECT MonthNumber + 1 
			FROM months
			WHERE MonthNumber < 11
		)
		
		select LEFT(DATENAME(MONTH,DATEADD(MONTH,c.MonthNumber,'2017-01-01 06:35:59.157')),3) AS WeekMonth,IsNull(Aggr1.price,0) AS Price 
		from
		(SELECT
		      IsNull(SUM( temp.Price ),0)  AS Price,
			  MONTH(temp.created_on) MonthNo			  
			  FROM #Temp_MonthlyInventorySummary temp  				
			  GROUP BY MONTH(created_on)) 
			  Aggr1 right outer JOIN months c on Aggr1.MonthNo-1 =c.MonthNumber				
END



GO
/****** Object:  StoredProcedure [dbo].[save_update_pharmacy_upsaccount]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================
-- Author:      Sagar Sharma
-- Create date: 05-07-2018
-- Description: SP to INSERT or UPDATE ups account details of a pharmacy
-- =============================================

CREATE PROCEDURE [dbo].[save_update_pharmacy_upsaccount]
	(
	@upsaccountid			INT,
	@pharmacyid				INT,
	@username				NVARCHAR(500),
	@password				NVARCHAR(500),
	@accesslicensenumber	NVARCHAR(500),
	@name					NVARCHAR(500),
	@addressline			NVARCHAR(500),
	@city					NVARCHAR(500),
	@statecode				NVARCHAR(500),
	@postalcode				NVARCHAR(500),
	@phonenumber			NVARCHAR(500),
	@upsaccountnumber		NVARCHAR(500)
	)
 AS 
 BEGIN
		IF(@upsaccountid>0)
			BEGIN
				UPDATE pharmacy_ups_account 
					SET
						pharmacy_id =			@pharmacyid,
						username =				@username,
						password =				@password,
						accesslicensenumber =	@accesslicensenumber,
						name =					@name,
						addressline =			@addressline,
						city =					@city,
						statecode =				@statecode,
						postalcode =			@postalcode,
						phonenumber =			@phonenumber,
						upsaccountnumber =      @upsaccountnumber 
					WHERE 
						pharmacy_ups_account_id = @upsaccountid
			
			END

		ELSE
			BEGIN
				INSERT INTO pharmacy_ups_account( pharmacy_id, username, password, accesslicensenumber,name, addressline, city, statecode, postalcode, phonenumber,upsaccountnumber)
					VALUES(@pharmacyid, @username, @password, @accesslicensenumber, @name, @addressline, @city, @statecode, @postalcode, @phonenumber,@upsaccountnumber)
			END


END





GO
/****** Object:  StoredProcedure [dbo].[Search_Pharmacy_address_List]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[Search_Pharmacy_address_List]
	(
	@search_string nvarchar(50)
	)
	  AS 
     
	     IF(@search_string='')
		  BEGIN
		    Select TOP 1 * from sa_pharmacy AS Pharmacy  INNER JOIN sa_superAdmin_sddress AS SuperAdmin_Address ON
			Pharmacy.pharmacy_id=SuperAdmin_Address.pharmacy_id
			WHERE Pharmacy.is_deleted = 0
			END
	     ELSE
		  BEGIN
	        Select TOP 1 * from sa_pharmacy AS PharmacyS  INNER JOIN sa_superAdmin_sddress AS SuperAdmin_AddressS ON
			PharmacyS.pharmacy_id=SuperAdmin_AddressS.pharmacy_id
			WHERE pharmacy_name like '%'+@search_string+'%' AND ( PharmacyS.is_deleted = 0)
          END





GO
/****** Object:  StoredProcedure [dbo].[SP_authentication]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================    
-- Create date: 13-03-2019    
-- Description: SP to Authenticate User    
-- By Humera Sheikh    
-- EXEC SP_Authentication 'Atoth@plumstedpharmacy.com '    
-- =============================================    
CREATE PROC [dbo].[SP_authentication] @username NVARCHAR(100) 
AS 
  BEGIN 
      DECLARE @SuperAdmin         INT, 
              @PharmacyAdmin      INT, 
              @PharmacyStaff      INT, 
              @subscriptionPlanId INT, 
              @ROLEID             INT, 
              @PlanExpDate        DATETIME, 
              @PharmacyId         INT, 
              @UserId             INT, 
              @Email              NVARCHAR(500), 
              @role               NVARCHAR(500), 
              @IsExpired          BIT, 
              @IsSubsActive       BIT, 
              @PasswordSalt       NVARCHAR(500), 
              @PasswordHash       NVARCHAR(500); 

      SET @PharmacyAdmin = 101 
      SET @PharmacyStaff = 102 
      SET @SuperAdmin = 100 

      SELECT @UserId = u.id, 
             @Email = u.email, 
             @ROLEID = ur.roleid, 
             @PharmacyId = Isnull(u.pharmacy_id, 0), 
             @PasswordHash = u.passwordhash, 
             @PasswordSalt = u.passwordsalt 
      FROM   users U 
             INNER JOIN userroles UR 
                     ON ur.userid = u.id 
      WHERE  u.email = @username 
              OR u.username = @username 

      SELECT @role = role 
      FROM   [dbo].[roles] 
      WHERE  id = @ROLEID 

	  /*BEGIN : check for SuperAdmin*/
      IF( @ROLEID = @SuperAdmin ) 
        BEGIN 
            SELECT @UserId       AS userId, 
                   @username     AS username, 
                   @ROLEID       AS roleId, 
                   @role         AS role, 
                   @Email        AS email, 
                   @PasswordHash AS PasswordHash, 
                   @PasswordSalt AS PasswordSalt 
        END 
    /* END: check for SuperAdmin */

      IF ( ( @ROLEID = @PharmacyAdmin ) 
            OR ( @ROLEID = @PharmacyStaff ) ) 
        BEGIN 
            SELECT @IsExpired = CASE 
                                  WHEN (SELECT Count(pharmacy_id) 
                                        FROM   pharmacy_list 
                                        WHERE  pharmacy_id = @PharmacyId 
                                               AND is_deleted = 0 
                                               AND subscription_status = '1' 
                                               AND ( Isnull(planexpiredt, 0) = 0 
                                                      OR planexpiredt = Getdate( 
                                                         ) 
                                                      OR planexpiredt < Getdate( 
                                                         ) 
                                                   )) =  0 
                                THEN 0 
                                  WHEN (SELECT Count(pharmacy_id) 
                                        FROM   pharmacy_list 
                                        WHERE  pharmacy_id = @PharmacyId 
                                               AND is_deleted = 0 
                                               AND subscription_status = '1' 
                                               AND ( Isnull(planexpiredt, 0) = 0 
                                                      OR planexpiredt = Getdate( 
                                                         ) 
                                                      OR planexpiredt < Getdate( 
                                                         ) 
                                                   )) >  0 
                                THEN 1 
                                END 

            SELECT @subscriptionPlanId = subscription_plan_id, 
                   @IsSubsActive = subscription_status 
            FROM   pharmacy_list 
            WHERE  pharmacy_id = @PharmacyId 

            SELECT @UserId             AS userId, 
                   @username           AS username, 
                   @ROLEID             AS roleId, 
                   @role               AS role, 
                   @Email              AS email, 
                   @PharmacyId         AS pharmacyId, 
                   @subscriptionPlanId AS subscriptionId, 
                   @IsExpired          AS ISEXPIRED, 
                   @IsSubsActive       AS IsSubscriptionActive, 
                   @PasswordHash       AS PasswordHash, 
                   @PasswordSalt       AS PasswordSalt 
        END 
  END 
GO
/****** Object:  StoredProcedure [dbo].[SP_authentication_BK_28_03_2019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================   
-- Create date: 13-03-2019   
-- Description: SP to Authenticate User   
-- By Humera Sheikh   
-- EXEC SP_Authentication 'Atoth@plumstedpharmacy.com'   
-- =============================================   
CREATE PROC [dbo].[SP_authentication_BK_28_03_2019] 
@username NVARCHAR(100) 
AS 
  BEGIN 
      DECLARE @SuperAdmin         INT, 
              @PharmacyAdmin      INT, 
              @PharmacyStaff      INT, 
              @subscriptionPlanId INT, 
              @ROLEID             INT, 
              @PlanExpDate        DATETIME, 
              @PharmacyId         INT, 
              @UserId             INT, 
              @Email              NVARCHAR(500), 
              @role               NVARCHAR(500), 
              @IsExpired          BIT, 
              @IsSubsActive       BIT, 
              @PasswordSalt       NVARCHAR(500), 
              @PasswordHash       NVARCHAR(500); 
	
		SET @PharmacyAdmin = 101
		SET @PharmacyStaff = 102
      
	  SELECT @UserId = u.id, 
             @Email = u.email, 
             @ROLEID = ur.roleid, 
             @PharmacyId = u.pharmacy_id, 
             @PasswordHash = u.passwordhash, 
             @PasswordSalt = u.passwordsalt 
      FROM   users U 
             INNER JOIN userroles UR 
                     ON ur.userid = u.id 
      WHERE  u.email = @username 
              OR u.username = @username 

      IF ( (@ROLEID = @PharmacyAdmin) 
            OR (@ROLEID = @PharmacyStaff )) 
        BEGIN 
            SELECT @IsExpired = 
			CASE 
                                  WHEN (SELECT Count(pharmacy_id) 
                                        FROM   pharmacy_list 
                                        WHERE  pharmacy_id = @PharmacyId 
                                               AND is_deleted = 0 
                                               AND subscription_status = '1' 
                                               AND ( Isnull(planexpiredt, 0) = 0 
                                                      OR planexpiredt = Getdate( 
                                                         ) 
                                                      OR planexpiredt < Getdate( 
                                                         ) 
                                                   )) = 0
                                THEN 0 
                                  WHEN (SELECT Count(pharmacy_id) 
                                        FROM   pharmacy_list 
                                        WHERE  pharmacy_id = @PharmacyId 
                                               AND is_deleted = 0 
                                               AND subscription_status = '1' 
                                               AND ( Isnull(planexpiredt, 0) = 0 
                                                      OR planexpiredt = Getdate( 
                                                         ) 
                                                      OR planexpiredt < Getdate( 
                                                         ) 
                                                   )) > 0
                                THEN 1
								 
                                END 

            SELECT @subscriptionPlanId = subscription_plan_id, 
                   @IsSubsActive = subscription_status 
            FROM   pharmacy_list 
            WHERE  pharmacy_id = @PharmacyId 

            SELECT @role = role 
            FROM   [dbo].[roles] 
            WHERE  id = @ROLEID 

            SELECT @UserId             AS userId, 
                   @username           AS username, 
                   @ROLEID             AS roleId, 
                   @role               AS role, 
                   @Email              AS email, 
                   @PharmacyId         AS pharmacyId, 
                   @subscriptionPlanId AS subscriptionId, 
                   @IsExpired          AS ISEXPIRED, 
                   @IsSubsActive       AS IsSubscriptionActive, 
                   @PasswordHash       AS PasswordHash, 
                   @PasswordSalt       AS PasswordSalt 
        END 
  END 


GO
/****** Object:  StoredProcedure [dbo].[sp_collaborativetrend]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author:      Sagar Sharma
-- Create date: 02-04-2018
-- Description: SP to calculculate the sales and purchase count month wise for collaborative trend
-- EXEC sp_collaborativetrend 426507, 1417
-- =============================================
	CREATE PROC [dbo].[sp_collaborativetrend]
	  @inventoryId INT,
	  @pharmacyId INT
	    
		AS
	   BEGIN		
	   DECLARE @ndcCode BIGINT
	   DECLARE @NdcPackSize DECIMAL(10,2)
	   SELECT @ndcCode = ndc, @NdcPackSize = NDC_Packsize  from inventory where (inventory_id = @inventoryId and pharmacy_id = @pharmacyId)
	 
	-- find the sales record from Rx30 inventory table on month basis.
	Select SUM(qty_disp) AS salesQty ,DateName(mm,DATEADD(mm,Month(created_on),-1)) as [MonthName],
	ndc,Month(created_on) MON
	into #TempSalesRecord
	from RX30_inventory  
	/*Commented where clouse and rewrote to get current year data.
	where ndc = @ndcCode*/ 
	where (ndc = @ndcCode) AND  (YEAR(getdate()) = YEAR(created_on))
	group by Month(created_on),ndc
	
	select ISNULL(t.salesQty, 0) salesQty, t.[MonthName], ISNULL(t.ndc, 0) ndc, CTE.monthno AS MON
	into #TempSalesRecord1
	from 
	(SELECT 1 as monthno
	 UNION ALL
	 SELECT 2 as monthno
	 UNION ALL
	 SELECT 3 as monthno
	 UNION ALL
	 SELECT 4 as monthno
	 UNION ALL
	 SELECT 5 as monthno
	 UNION ALL
	 SELECT 6 as monthno
	 UNION ALL
	 SELECT 7 as monthno
	 UNION ALL
	 SELECT 8 as monthno
	 UNION ALL
	 SELECT 9 as monthno
	 UNION ALL
	 SELECT 10 as monthno
	 UNION ALL
	 SELECT 11 as monthno
	 UNION ALL
	 SELECT 12 as monthno) AS CTE
	 LEFT JOIN #TempSalesRecord t ON CTE.monthno = t.MON

--===========================================================================	
	-- return the purchase quantity month wise for edi purchase 
	
	 --DECLARE @ndcCode BIGINT
	 --DECLARE @NdcPackSize DECIMAL(10,2)
	 --SET @ndcCode = 591211481
	 --SET @NdcPackSize =100
	 --set @NdcPackSize = 1 --prashant
	 SELECT (SUM(CONVERT(INT,ISNULL(invli.invoiced_quantity,0)))* @NdcPackSize)    AS	 invPurchaseQty,
	 DateName(mm,DATEADD(mm,Month(inv.created_on),-1))							  AS	 [MonthName],
	CONVERT(BIGINT,ISNULL(invli.ndc_upc,0))										  AS	 ndc , 
	Month(inv.created_on)														  AS	 MON
	INTO #TempINVPurchaseRecord
	FROM invoice_line_items invli
	 INNER JOIN invoice inv ON invli.invoice_id = inv.invoice_id
	 WHERE CONVERT(BIGINT,invli.ndc_upc) = @ndcCode
	  /*ADDED year condtiotion*/
	 AND (YEAR(getdate()) = YEAR(inv.created_on))
	GROUP BY Month(inv.created_on), invli.ndc_upc


	SELECT ISNULL(tinv.invPurchaseQty, 0) purchaseQty, tinv.[MonthName], ISNULL(tinv.ndc, 0) ndc, CTE.monthno AS MON
	 INTO #TempPurchaseRecordedi
	FROM(SELECT 1 as monthno
	 UNION ALL
	 SELECT 2 as monthno
	 UNION ALL
	 SELECT 3 as monthno
	 UNION ALL
	 SELECT 4 as monthno
	 UNION ALL
	 SELECT 5 as monthno
	 UNION ALL
	 SELECT 6 as monthno
	 UNION ALL
	 SELECT 7 as monthno
	 UNION ALL
	 SELECT 8 as monthno
	 UNION ALL
	 SELECT 9 as monthno
	 UNION ALL
	 SELECT 10 as monthno
	 UNION ALL
	 SELECT 11 as monthno
	 UNION ALL
	 SELECT 12 as monthno) AS CTE
	 LEFT JOIN #TempINVPurchaseRecord tinv ON CTE.monthno = tinv.MON


--===========================================================================	
	-- return the purchase quantity month wise for csv import

	Select SUM(pack_size) AS purchaseQty ,DateName(mm,DATEADD(mm,Month(created_on),-1)) as [MonthName],
	ndc,Month(created_on) MON
	into #TempPurchaseRecord
	from wholesaler_csv_Import  where ndc = @ndcCode
	/*added year condition*/
	 AND (YEAR(getdate()) = YEAR(created_on))
	group by Month(created_on),ndc

	select ISNULL(t.purchaseQty, 0) purchaseQty, t.[MonthName], ISNULL(t.ndc, 0) ndc, CTE.monthno AS MON
	 into #TempPurchaseRecord1
	from(SELECT 1 as monthno
	 UNION ALL
	 SELECT 2 as monthno
	 UNION ALL
	 SELECT 3 as monthno
	 UNION ALL
	 SELECT 4 as monthno
	 UNION ALL
	 SELECT 5 as monthno
	 UNION ALL
	 SELECT 6 as monthno
	 UNION ALL
	 SELECT 7 as monthno
	 UNION ALL
	 SELECT 8 as monthno
	 UNION ALL
	 SELECT 9 as monthno
	 UNION ALL
	 SELECT 10 as monthno
	 UNION ALL
	 SELECT 11 as monthno
	 UNION ALL
	 SELECT 12 as monthno) AS CTE
	 LEFT JOIN #TempPurchaseRecord t ON CTE.monthno = t.MON

--===========================================================================	
--Combine the purchase quantity(sum month wise) of edi and csv purchase

	UPDATE temppurchaseCSV 
	SET temppurchaseCSV.purchaseQty = temppurchaseCSV.purchaseQty + temppurchaseEDI.purchaseQty,
		temppurchaseCSV.MonthName = temppurchaseCSV.MonthName,
		temppurchaseCSV.ndc = temppurchaseCSV.ndc,
		temppurchaseCSV.MON = temppurchaseCSV.MON 
	FROM #TempPurchaseRecord1  temppurchaseCSV
	INNER JOIN #TempPurchaseRecordedi  temppurchaseEDI ON temppurchaseCSV.MON = temppurchaseEDI.MON

	--select * from #TempPurchaseRecord1

--===========================================================================	
	 -- combine the sales and purchase count month wise and return it.
	 SELECT pt.purchaseQty as PurchaseQty, st.salesQty as salesQty,  st.MonthName as month, st.ndc as ndc , st.MON as monthNo
	 FROM #TempSalesRecord1 as st left join #TempPurchaseRecord1 as pt
	 on st.MON = pt.MON


	DROP TABLE #TempSalesRecord
	DROP TABLE #TempSalesRecord1
	DROP TABLE #TempPurchaseRecord
	DROP TABLE #TempPurchaseRecord1
	DROP TABLE #TempINVPurchaseRecord
	DROP TABLE #TempPurchaseRecordedi

	
	  END
 -----






--Select * from RX30_inventory  where ndc = 642012590

--Update RX30_inventory set created_on = DATEADD(month, -2, GETDATE()) WHERE rx30_inventory_id = 20080


--select datename(month, '01-Jan-2018')


-- select * from RX30_inventory order by 1 desc 








GO
/****** Object:  StoredProcedure [dbo].[sp_collaborativetrend_backup_11_07_2018]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author:      Sagar Sharma
-- Create date: 02-04-2018
-- Description: SP to calculculate the sales and purchase count month wise for collaborative trend
-- EXEC sp_collaborativetrend 426780, 1417
-- =============================================
	Create PROC [dbo].[sp_collaborativetrend_backup_11_07_2018]
	  @inventoryId INT,
	  @pharmacyId INT
	    
		AS
	   BEGIN		
	   DECLARE @ndcCode BIGINT

	  SELECT @ndcCode = ndc from inventory where (inventory_id = @inventoryId and pharmacy_id = @pharmacyId)
	 
	-- find the sales record from Rx30 inventory table on month basis.
	Select SUM(qty_disp) AS salesQty ,DateName(mm,DATEADD(mm,Month(created_on),-1)) as [MonthName],
	ndc,Month(created_on) MON
	into #TempSalesRecord
	from RX30_inventory  where ndc = @ndcCode
	group by Month(created_on),ndc
	
	select ISNULL(t.salesQty, 0) salesQty, t.[MonthName], ISNULL(t.ndc, 0) ndc, CTE.monthno AS MON
	into #TempSalesRecord1
	from 
	(SELECT 1 as monthno
	 UNION ALL
	 SELECT 2 as monthno
	 UNION ALL
	 SELECT 3 as monthno
	 UNION ALL
	 SELECT 4 as monthno
	 UNION ALL
	 SELECT 5 as monthno
	 UNION ALL
	 SELECT 6 as monthno
	 UNION ALL
	 SELECT 7 as monthno
	 UNION ALL
	 SELECT 8 as monthno
	 UNION ALL
	 SELECT 9 as monthno
	 UNION ALL
	 SELECT 10 as monthno
	 UNION ALL
	 SELECT 11 as monthno
	 UNION ALL
	 SELECT 12 as monthno) AS CTE
	 LEFT JOIN #TempSalesRecord t ON CTE.monthno = t.MON
	

	-- return the purchase quantity month wise
	 Select SUM(pack_size) AS purchaseQty ,DateName(mm,DATEADD(mm,Month(created_on),-1)) as [MonthName],
	ndc,Month(created_on) MON
	into #TempPurchaseRecord
	from wholesaler_csv_Import  where ndc = @ndcCode
	group by Month(created_on),ndc

	select ISNULL(t.purchaseQty, 0) purchaseQty, t.[MonthName], ISNULL(t.ndc, 0) ndc, CTE.monthno AS MON
	 into #TempPurchaseRecord1
	from(SELECT 1 as monthno
	 UNION ALL
	 SELECT 2 as monthno
	 UNION ALL
	 SELECT 3 as monthno
	 UNION ALL
	 SELECT 4 as monthno
	 UNION ALL
	 SELECT 5 as monthno
	 UNION ALL
	 SELECT 6 as monthno
	 UNION ALL
	 SELECT 7 as monthno
	 UNION ALL
	 SELECT 8 as monthno
	 UNION ALL
	 SELECT 9 as monthno
	 UNION ALL
	 SELECT 10 as monthno
	 UNION ALL
	 SELECT 11 as monthno
	 UNION ALL
	 SELECT 12 as monthno) AS CTE
	 LEFT JOIN #TempPurchaseRecord t ON CTE.monthno = t.MON






	 -- combine the sales and purchase count month wise and return it.
	 SELECT pt.purchaseQty as PurchaseQty, st.salesQty as salesQty,  st.MonthName as month, st.ndc as ndc , st.MON as monthNo
	 FROM #TempSalesRecord1 as st left join #TempPurchaseRecord1 as pt
	 on st.MON = pt.MON


	Drop table #TempSalesRecord
	Drop table #TempSalesRecord1
	Drop table #TempPurchaseRecord
	Drop table #TempPurchaseRecord1

	
	  END
 -----






--Select * from RX30_inventory  where ndc = 642012590

--Update RX30_inventory set created_on = DATEADD(month, -2, GETDATE()) WHERE rx30_inventory_id = 20080


--select datename(month, '01-Jan-2018')


-- select * from RX30_inventory order by 1 desc 






GO
/****** Object:  StoredProcedure [dbo].[sp_collaborativetrend_bk_26032019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Sagar Sharma
-- Create date: 02-04-2018
-- Description: SP to calculculate the sales and purchase count month wise for collaborative trend
-- EXEC sp_collaborativetrend 426507, 1417
-- =============================================
	CREATE PROC [dbo].[sp_collaborativetrend_bk_26032019]
	  @inventoryId INT,
	  @pharmacyId INT
	    
		AS
	   BEGIN		
	   DECLARE @ndcCode BIGINT
	   DECLARE @NdcPackSize DECIMAL(10,2)
	   SELECT @ndcCode = ndc, @NdcPackSize = NDC_Packsize  from inventory where (inventory_id = @inventoryId and pharmacy_id = @pharmacyId)
	 
	-- find the sales record from Rx30 inventory table on month basis.
	Select SUM(qty_disp) AS salesQty ,DateName(mm,DATEADD(mm,Month(created_on),-1)) as [MonthName],
	ndc,Month(created_on) MON
	into #TempSalesRecord
	from RX30_inventory  where ndc = @ndcCode
	group by Month(created_on),ndc
	
	select ISNULL(t.salesQty, 0) salesQty, t.[MonthName], ISNULL(t.ndc, 0) ndc, CTE.monthno AS MON
	into #TempSalesRecord1
	from 
	(SELECT 1 as monthno
	 UNION ALL
	 SELECT 2 as monthno
	 UNION ALL
	 SELECT 3 as monthno
	 UNION ALL
	 SELECT 4 as monthno
	 UNION ALL
	 SELECT 5 as monthno
	 UNION ALL
	 SELECT 6 as monthno
	 UNION ALL
	 SELECT 7 as monthno
	 UNION ALL
	 SELECT 8 as monthno
	 UNION ALL
	 SELECT 9 as monthno
	 UNION ALL
	 SELECT 10 as monthno
	 UNION ALL
	 SELECT 11 as monthno
	 UNION ALL
	 SELECT 12 as monthno) AS CTE
	 LEFT JOIN #TempSalesRecord t ON CTE.monthno = t.MON

--===========================================================================	
	-- return the purchase quantity month wise for edi purchase 
	
	 --DECLARE @ndcCode BIGINT
	 --DECLARE @NdcPackSize DECIMAL(10,2)
	 --SET @ndcCode = 591211481
	 --SET @NdcPackSize =100
	 
	 SELECT (SUM(CONVERT(INT,ISNULL(invli.invoiced_quantity,0)))* @NdcPackSize)    AS	 invPurchaseQty,
	 DateName(mm,DATEADD(mm,Month(inv.created_on),-1))							  AS	 [MonthName],
	CONVERT(BIGINT,ISNULL(invli.ndc_upc,0))										  AS	 ndc , 
	Month(inv.created_on)														  AS	 MON
	INTO #TempINVPurchaseRecord
	FROM invoice_line_items invli
	 INNER JOIN invoice inv ON invli.invoice_id = inv.invoice_id
	 WHERE CONVERT(BIGINT,invli.ndc_upc) = @ndcCode
	GROUP BY Month(inv.created_on), invli.ndc_upc


	SELECT ISNULL(tinv.invPurchaseQty, 0) purchaseQty, tinv.[MonthName], ISNULL(tinv.ndc, 0) ndc, CTE.monthno AS MON
	 INTO #TempPurchaseRecordedi
	FROM(SELECT 1 as monthno
	 UNION ALL
	 SELECT 2 as monthno
	 UNION ALL
	 SELECT 3 as monthno
	 UNION ALL
	 SELECT 4 as monthno
	 UNION ALL
	 SELECT 5 as monthno
	 UNION ALL
	 SELECT 6 as monthno
	 UNION ALL
	 SELECT 7 as monthno
	 UNION ALL
	 SELECT 8 as monthno
	 UNION ALL
	 SELECT 9 as monthno
	 UNION ALL
	 SELECT 10 as monthno
	 UNION ALL
	 SELECT 11 as monthno
	 UNION ALL
	 SELECT 12 as monthno) AS CTE
	 LEFT JOIN #TempINVPurchaseRecord tinv ON CTE.monthno = tinv.MON


--===========================================================================	
	-- return the purchase quantity month wise for csv import

	Select SUM(pack_size) AS purchaseQty ,DateName(mm,DATEADD(mm,Month(created_on),-1)) as [MonthName],
	ndc,Month(created_on) MON
	into #TempPurchaseRecord
	from wholesaler_csv_Import  where ndc = @ndcCode
	group by Month(created_on),ndc

	select ISNULL(t.purchaseQty, 0) purchaseQty, t.[MonthName], ISNULL(t.ndc, 0) ndc, CTE.monthno AS MON
	 into #TempPurchaseRecord1
	from(SELECT 1 as monthno
	 UNION ALL
	 SELECT 2 as monthno
	 UNION ALL
	 SELECT 3 as monthno
	 UNION ALL
	 SELECT 4 as monthno
	 UNION ALL
	 SELECT 5 as monthno
	 UNION ALL
	 SELECT 6 as monthno
	 UNION ALL
	 SELECT 7 as monthno
	 UNION ALL
	 SELECT 8 as monthno
	 UNION ALL
	 SELECT 9 as monthno
	 UNION ALL
	 SELECT 10 as monthno
	 UNION ALL
	 SELECT 11 as monthno
	 UNION ALL
	 SELECT 12 as monthno) AS CTE
	 LEFT JOIN #TempPurchaseRecord t ON CTE.monthno = t.MON

--===========================================================================	
--Combine the purchase quantity(sum month wise) of edi and csv purchase

	UPDATE temppurchaseCSV 
	SET temppurchaseCSV.purchaseQty = temppurchaseCSV.purchaseQty + temppurchaseEDI.purchaseQty,
		temppurchaseCSV.MonthName = temppurchaseCSV.MonthName,
		temppurchaseCSV.ndc = temppurchaseCSV.ndc,
		temppurchaseCSV.MON = temppurchaseCSV.MON 
	FROM #TempPurchaseRecord1  temppurchaseCSV
	INNER JOIN #TempPurchaseRecordedi  temppurchaseEDI ON temppurchaseCSV.MON = temppurchaseEDI.MON

	--select * from #TempPurchaseRecord1

--===========================================================================	
	 -- combine the sales and purchase count month wise and return it.
	 SELECT pt.purchaseQty as PurchaseQty, st.salesQty as salesQty,  st.MonthName as month, st.ndc as ndc , st.MON as monthNo
	 FROM #TempSalesRecord1 as st left join #TempPurchaseRecord1 as pt
	 on st.MON = pt.MON


	DROP TABLE #TempSalesRecord
	DROP TABLE #TempSalesRecord1
	DROP TABLE #TempPurchaseRecord
	DROP TABLE #TempPurchaseRecord1
	DROP TABLE #TempINVPurchaseRecord
	DROP TABLE #TempPurchaseRecordedi

	
	  END
 -----






--Select * from RX30_inventory  where ndc = 642012590

--Update RX30_inventory set created_on = DATEADD(month, -2, GETDATE()) WHERE rx30_inventory_id = 20080


--select datename(month, '01-Jan-2018')


-- select * from RX30_inventory order by 1 desc 







GO
/****** Object:  StoredProcedure [dbo].[SP_CSVImportList]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Create date: 06-04-2018
-- Description: SP to show CSV Import list with pagination and serarching
--SP_CSVImportList 12,10,2,''
-- =============================================

CREATE PROC [dbo].[SP_CSVImportList]

  @pharmacy_id  int,
  @PageSize		int,
  @PageNumber    int,
  @SearchString  nvarchar(100)=null

	AS
   BEGIN
   DECLARE @count int;  

    

		SELECT
		 A.csvimport_batch_id     AS BatchId,
		 B.wholesaler_csv_id	  AS Wholesaler_vsc_Id,
		 B.drug_name			  AS DrugName,
		 B.ndc					  AS NDC,
		B.generic_code            AS GenericCode,
		B.pack_size				  AS Quantity,
		B.tax				      AS Tax,
		B.price                   AS Price,
		B.response                AS Response,
		B.status_id				  AS [Status],
		B.purchasedate			  AS PurchaseDate	
		INTO #Temp_csvdata
		FROM [dbo].[wholesaler_csvimport_batch_master] A JOIN [dbo].[wholesaler_CSV_Import] B
		ON A.csvimport_batch_id=B.csvbatch_id
		WHERE A.pharmacy_id=@pharmacy_id AND B.is_deleted IS NULL
		
		 SELECT @count=  IsNull (COUNT(*),0) FROM  #Temp_csvdata 
		 WHERE (DrugName LIKE '%'+ISNULL(@SearchString,DrugName)+'%' OR
		 NDC LIKE '%'+ISNULL(@SearchString,NDC)+'%')

		 SELECT 
		 BatchId,
		 Wholesaler_vsc_Id,
		 DrugName,
		 NDC,
		 GenericCode,
		 Quantity,
		 Tax,
		 Price,
		 Response,
		 Status,
		 @count AS Count ,
		 PurchaseDate
		  FROM  #Temp_csvdata 
		  WHERE 
		(DrugName LIKE '%'+ISNULL(@SearchString,DrugName)+'%' OR
		NDC LIKE '%'+ISNULL(@SearchString,NDC)+'%')
		ORDER BY Wholesaler_vsc_Id desc
		OFFSET  @PageSize * (@PageNumber - 1)   ROWS
		FETCH NEXT @PageSize ROWS ONLY	
  
  END




GO
/****** Object:  StoredProcedure [dbo].[SP_deadStockReport]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================

-- Create date: 24-04-2018
-- Updated date: 18-03-2019
-- Description: SP to show Dead stock report with pagination and serarching
-- Note: NDC may duplicate because price,strengh,quantity can be different  	

-- exec SP_deadStockReport 12,0,1,''
-- =============================================



CREATE PROC [dbo].[SP_deadStockReport]
  @pharmacy_id  INT,
  @PageSize		INT,
  @PageNumber    INT,
  @SearchString  NVARCHAR(100)=null

	AS
   BEGIN
		;WITH deadstock AS
		(
			SELECT				
				inv.ndc									AS Identifier
				,inv.drug_name							AS DrugName				
				,inv.created_on							AS  created_on
				,inv.pack_size							AS Quantity    
				,inv.price								AS Price    
				,inv.strength							AS Strength
				,ISNULL((inv.pack_size * inv.price),0)	AS ExtendedQuantity    
				,DATEDIFF(dd ,inv.created_on,GetDate())  AS Difference     
				,COUNT(1) OVER () AS Count
			FROM inventory inv
			WHERE(  (inv.pharmacy_id = @pharmacy_id) 
				AND (inv.is_deleted = 0)
				AND (DATEDIFF(dd ,inv.created_on,GetDate())  > 120)
				AND  (ISNULL(inv.pack_size,0) >0)			
			)			
			      
		)

		SELECT 			
			ds.Identifier
			,ds.DrugName
			,ds.created_on
			,ds.Quantity
			,ds.Price
			,ds.strength
			,ds.ExtendedQuantity
			,ds.Difference
			,ds.Count
		FROM deadstock ds
		WHERE (
			((ds.DrugName LIKE '%'+ISNULL(@SearchString,ds.DrugName)+'%') OR    
			   (ds.Identifier LIKE '%'+ISNULL(@SearchString,ds.Identifier)+'%'))   
		  ) 
		ORDER BY ds.Price desc
		OFFSET  @PageSize * (@PageNumber - 1)   ROWS    
		FETCH NEXT IIF(@PageSize = 0, 1000000, @PageSize) ROWS ONLY  

      /* commnented old logic
	  DECLARE @count int;    

   ;WITH deadstock AS
   (
    SELECT rx30_inventory_id,ndc,created_on FROM RX30_inventory 
	WHERE (    
	  (pharmacy_id = @pharmacy_id) AND     
	  (is_deleted IS NULL)    
	   AND       
	  (DATEDIFF(dd ,created_on,GetDate())  > 120)    
	  ) 
   )

   SELECT     
	   ds.rx30_inventory_id     AS Rx30InventoryId,    
	   @pharmacy_id      AS PharmacyId,    
	   inv.drug_name       AS DrugName,    
	   ds.ndc        AS Identifier,    
	   inv.pack_size       AS Quantity,    
	   inv.price        AS Price,    
	   inv.strength       AS Strength,    
	   ISNULL((inv.pack_size * inv.price),0)  AS ExtendedQuantity,    
	   DATEDIFF(dd ,ds.created_on,GetDate())  AS Difference,    
	   COUNT(1) OVER () AS Count  
   FROM deadstock ds 
     INNER JOIN inventory inv ON ds.ndc = inv.ndc    
	   WHERE ((inv.pack_size > 0) AND (inv.is_deleted = 0) AND    
		 ((inv.drug_name LIKE '%'+ISNULL(@SearchString,inv.drug_name)+'%') OR    
			   (ds.ndc LIKE '%'+ISNULL(@SearchString,ds.ndc)+'%'))   
		  ) 
  ORDER BY inv.Price desc 
  OFFSET  @PageSize * (@PageNumber - 1)   ROWS    
  FETCH NEXT IIF(@PageSize = 0, 1000000, @PageSize) ROWS ONLY  
*/	 
  END
  








GO
/****** Object:  StoredProcedure [dbo].[SP_deadStockReport_backUp_19-06-2018]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================

-- Author:      Priyanka Chandak

-- Create date: 24-04-2018

-- Description: SP to show Dead stock report with pagination and serarching

-- =============================================



CREATE PROC [dbo].[SP_deadStockReport_backUp_19-06-2018]

  @pharmacy_id  int,

  @PageSize		int,

  @PageNumber    int,

  @SearchString  nvarchar(100)=null



	AS

   BEGIN

   DECLARE @count int;



	 SELECT * INTO #TEMP_deadstock

	 FROM RX30_inventory

	 WHERE pharmacy_id = @pharmacy_id AND (drug_name LIKE '%'+ISNULL(@SearchString,drug_name)+'%' OR

		 ndc LIKE '%'+ISNULL(@SearchString,ndc)+'%') AND  DATEDIFF(dd ,created_on,GetDate())  > 120		



  

	 SELECT @Count = (ISNULL(COUNT(*),0)) FROM #TEMP_deadstock



      SELECT 

		 rx30_inventory_id					AS Rx30InventoryId,

		 pharmacy_id						AS PharmacyId,

		 drug_name							AS DrugName,

		 ndc								AS Identifier,

		 pack_size							AS Quantity,

		 price								AS Price,

		 ISNULL((pack_size * price),0)		AS ExtendedQuantity,

		 DATEDIFF(dd ,created_on,GetDate())  AS Difference,

		 @count								AS Count

		 FROM #TEMP_deadstock 



		 ORDER BY Price desc

		 OFFSET  @PageSize * (@PageNumber - 1)   ROWS

         FETCH NEXT @PageSize ROWS ONLY	



		 drop table #TEMP_deadstock



  END





  --exec SP_deadStockReport 1,10,1,''








GO
/****** Object:  StoredProcedure [dbo].[SP_deadStockReport_bk_18032019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================

-- Create date: 24-04-2018

-- Description: SP to show Dead stock report with pagination and serarching

-- exec SP_deadStockReport 12,0,1,''
-- =============================================



CREATE PROC [dbo].[SP_deadStockReport_bk_18032019]

  @pharmacy_id  int,
  @PageSize		int,
  @PageNumber    int,
  @SearchString  nvarchar(100)=null

	AS
   BEGIN
      DECLARE @count int;    

   ;WITH deadstock AS
   (
    SELECT rx30_inventory_id,ndc,created_on FROM RX30_inventory 
	WHERE (    
	  (pharmacy_id = @pharmacy_id) AND     
	  (is_deleted IS NULL)    
	   AND       
	  (DATEDIFF(dd ,created_on,GetDate())  > 120)    
	  ) 
   )

   SELECT     
	   ds.rx30_inventory_id     AS Rx30InventoryId,    
	   @pharmacy_id      AS PharmacyId,    
	   inv.drug_name       AS DrugName,    
	   ds.ndc        AS Identifier,    
	   inv.pack_size       AS Quantity,    
	   inv.price        AS Price,    
	   inv.strength       AS Strength,    
	   ISNULL((inv.pack_size * inv.price),0)  AS ExtendedQuantity,    
	   DATEDIFF(dd ,ds.created_on,GetDate())  AS Difference,    
	   COUNT(1) OVER () AS Count  
   FROM deadstock ds 
     INNER JOIN inventory inv ON ds.ndc = inv.ndc    
	   WHERE ((inv.pack_size > 0) AND (inv.is_deleted = 0) AND    
		 ((inv.drug_name LIKE '%'+ISNULL(@SearchString,inv.drug_name)+'%') OR    
			   (ds.ndc LIKE '%'+ISNULL(@SearchString,ds.ndc)+'%'))   
		  ) 
  ORDER BY inv.Price desc 
  OFFSET  @PageSize * (@PageNumber - 1)   ROWS    
  FETCH NEXT IIF(@PageSize = 0, 1000000, @PageSize) ROWS ONLY  
	 
  END
  








GO
/****** Object:  StoredProcedure [dbo].[SP_deadStockReport_BK13032019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================

-- Create date: 24-04-2018

-- Description: SP to show Dead stock report with pagination and serarching

-- exec SP_deadStockReport_BK13032019t 12,0,1,''
-- =============================================



CREATE PROC [dbo].[SP_deadStockReport_BK13032019]

  @pharmacy_id  int,
  @PageSize		int,
  @PageNumber    int,
  @SearchString  nvarchar(100)=null

	AS
   BEGIN

   DECLARE @count int;

	 SELECT * INTO #TEMP_deadstock
	  FROM RX30_inventory
	   WHERE (
	     (pharmacy_id = @pharmacy_id) AND 
		(is_deleted IS NULL)
		 AND 	 
		(DATEDIFF(dd ,created_on,GetDate())  > 120)
	 )		  
		 
	
  IF @PageSize > 0
	 BEGIN

	    SELECT @Count = (ISNULL(COUNT(*),0)) FROM  #TEMP_deadstock tempds
		  INNER JOIN inventory inv ON tempds.ndc = inv.ndc
		 WHERE ((inv.pack_size > 0) AND (inv.is_deleted = 0) AND
		 ((inv.drug_name LIKE '%'+ISNULL(@SearchString,inv.drug_name)+'%') OR
	      (tempds.ndc LIKE '%'+ISNULL(@SearchString,tempds.ndc)+'%'))
		 ) 

	 SELECT 
		 tempds.rx30_inventory_id					AS Rx30InventoryId,
		 tempds.pharmacy_id						AS PharmacyId,
		 inv.drug_name							AS DrugName,
		 tempds.ndc								AS Identifier,
		 inv.pack_size							AS Quantity,
		 inv.price								AS Price,
		 inv.strength							AS Strength,
		 ISNULL((inv.pack_size * inv.price),0)		AS ExtendedQuantity,
		 DATEDIFF(dd ,tempds.created_on,GetDate())  AS Difference,
		 @count								AS Count
	
		 FROM #TEMP_deadstock tempds
		  INNER JOIN inventory inv ON tempds.ndc = inv.ndc
		 WHERE ((inv.pack_size > 0) AND (inv.is_deleted = 0) AND
		 ((inv.drug_name LIKE '%'+ISNULL(@SearchString,inv.drug_name)+'%') OR
	      (tempds.ndc LIKE '%'+ISNULL(@SearchString,tempds.ndc)+'%'))
		 ) 
		
	END
	ELSE
	BEGIN

	 SELECT @Count = (ISNULL(COUNT(*),0)) FROM  #TEMP_deadstock tempds
		  INNER JOIN inventory inv ON tempds.ndc = inv.ndc
		 WHERE ((inv.pack_size > 0) AND (inv.is_deleted = 0)	
		 ) 

	 SELECT 
		 tempds.rx30_inventory_id					AS Rx30InventoryId,
		 tempds.pharmacy_id						AS PharmacyId,
		 inv.drug_name							AS DrugName,
		 tempds.ndc								AS Identifier,
		 inv.pack_size							AS Quantity,
		 inv.price								AS Price,
		  inv.strength							AS Strength,
		 ISNULL((inv.pack_size * inv.price),0)		AS ExtendedQuantity,
		 DATEDIFF(dd ,tempds.created_on,GetDate())  AS Difference,
		 @count								AS Count
	
		 FROM #TEMP_deadstock tempds
		 INNER JOIN inventory inv ON tempds.ndc = inv.ndc
		 WHERE ((inv.pack_size > 0) AND (inv.is_deleted = 0)
		 AND
		 ((inv.drug_name LIKE '%'+ISNULL(@SearchString,inv.drug_name)+'%') OR
	      (tempds.ndc LIKE '%'+ISNULL(@SearchString,tempds.ndc)+'%')		  
		 ))
		 ORDER BY inv.Price desc
	
	END	 
		
	 drop table #TEMP_deadstock
	 
  END
  







GO
/****** Object:  StoredProcedure [dbo].[SP_deadStockReport_debug]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================

-- Create date: 24-04-2018

-- Description: SP to show Dead stock report with pagination and serarching

-- exec SP_deadStockReport 12,0,1,''
-- =============================================



CREATE PROC [dbo].[SP_deadStockReport_debug]

  @pharmacy_id  int,
  @PageSize		int,
  @PageNumber    int,
  @SearchString  nvarchar(100)=null

	AS
   BEGIN
      DECLARE @count int;    
	  SET STATISTICS TIME ON;  
   ;WITH deadstock AS
   (
    SELECT rx30_inventory_id,ndc,created_on FROM RX30_inventory 
	WHERE (    
	  (pharmacy_id = @pharmacy_id) AND     
	  (ISNULL(is_deleted,0) =0)    
	   AND       
	  /*(DATEDIFF(dd ,created_on,GetDate())  > 120)*/
	  created_on < DATEADD(dd,-120,GETDATE())    
	  )	
   )
   --datediff(dd, senddate, @RunDate) > @CalculationInterval
   --WHERE senddate < dateadd(dd, -@CalculationInterval, @RunDate)
      
   SELECT     
	   ds.rx30_inventory_id     AS Rx30InventoryId,    
	   @pharmacy_id      AS PharmacyId,    
	   inv.drug_name       AS DrugName,    
	   ds.ndc        AS Identifier,    
	   inv.pack_size       AS Quantity,    
	   inv.price        AS Price,    
	   inv.strength       AS Strength,    
	   ISNULL((inv.pack_size * inv.price),0)  AS ExtendedQuantity,    
	   DATEDIFF(dd ,ds.created_on,GetDate())  AS Difference,    
	   COUNT(1) OVER () AS Count  
   FROM deadstock ds 
     INNER JOIN inventory inv ON ds.ndc = inv.ndc    
	   WHERE ((inv.pack_size > 0) AND (inv.is_deleted = 0) AND    
		 ((inv.drug_name LIKE '%'+ISNULL(@SearchString,inv.drug_name)+'%') OR    
			   (ds.ndc LIKE '%'+ISNULL(@SearchString,ds.ndc)+'%'))   
		  ) 
  ORDER BY inv.Price desc 
  OFFSET  @PageSize * (@PageNumber - 1)   ROWS    
  FETCH NEXT IIF(@PageSize = 0, 1000000, @PageSize) ROWS ONLY  
	 SET STATISTICS TIME OFF;  
  END
  








GO
/****** Object:  StoredProcedure [dbo].[SP_delete_broadcastmessage]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Sagar Sharma
-- Create date: 08-01-2018
-- Description: SP to soft delete the broadcast message.
-- =============================================

CREATE PROCEDURE [dbo].[SP_delete_broadcastmessage]
	(
	@messageId				int
	)
 AS 
 BEGIN

	 IF(@messageId> 0)
	  BEGIN
		DELETE FROM broadcast_message WHERE broadcast_message_id = @messageId;
	   END 
		
END;


GO
/****** Object:  StoredProcedure [dbo].[SP_delete_orderdetails]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author:      Sagar Sharma
-- Create date: 02-04-2018
-- Description: SP to INSERT or UPDATE the Order Details for a pharmacy
-- =============================================

CREATE PROCEDURE [dbo].[SP_delete_orderdetails]
	(
	@orderId				int
	)
 AS 
 BEGIN

 SET NOCOUNT ON;
	 IF(@orderId> 0)
	  BEGIN
		DELETE FROM order_details WHERE order_id = @orderId;
	   END 
		
	SET NOCOUNT OFF;
END;




GO
/****** Object:  StoredProcedure [dbo].[SP_delete_pharmacy]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================
-- Author:      Sagar Sharma
-- Create date: 27-02-2018
-- Description: SP to INSERT or UPDATE the record in pharmacy table
-- =============================================

/*
	EXEC SP_delete_pharmacy 1, 2
	Select * from pharmacy
*/

CREATE PROCEDURE [dbo].[SP_delete_pharmacy]
(  
	@id					INTEGER,
	@deleted_by			INTEGER
)  
AS  
BEGIN 
	UPDATE pharmacy SET  
		deleted_on = GETDATE(),
		deleted_by = @deleted_by,
		is_deleted = 1 
	WHERE  pharmacy_id = @id 

	UPDATE address_master SET  
		deleted_on = GETDATE(),
		deleted_by = @deleted_by,
		is_deleted = 1 
	WHERE  pharmacy_id = @id 

	
END 





GO
/****** Object:  StoredProcedure [dbo].[SP_Delete_saInvoice]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 27-02-2018
-- Description: SP to DELETE SuperAdmin Invoice table
-- =============================================

	CREATE PROCEDURE [dbo].[SP_Delete_saInvoice](
	@id int,
	@deleted_by int
	)
  AS 
 
  IF (@id IS NOT NULL) OR (LEN(@id) > 0)
	BEGIN
	 UPDATE sa_superadmin_invoice SET deleted_by=@deleted_by,deleted_on=GETDATE(),is_deleted=1 WHERE superadmin_invoice_id=@id
	 UPDATE sa_invoice_payment_details SET deleted_by=@deleted_by,deleted_on=GETDATE(),is_deleted=1 WHERE superadmin_invoice_id=@id
	 return @id
	END




GO
/****** Object:  StoredProcedure [dbo].[SP_Delete_saPharmacyOwner]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
 -- =============================================
-- Author:      Priyanka Chandak
-- Create date: 27-02-2018
-- Description: SP to SOFT DELETE pharmacy owner
-- =============================================
CREATE PROCEDURE [dbo].[SP_Delete_saPharmacyOwner](
	@id int,
	@deleted_by int
)
  AS 
 
  IF (@id IS NOT NULL) OR (LEN(@id) > 0)
	BEGIN
	 UPDATE sa_pharmacy_owner SET deleted_by=@deleted_by,deleted_on=GETDATE(),is_deleted=1 WHERE pharmacy_owner_id=@id
	 UPDATE sa_superAdmin_sddress SET deleted_by=@deleted_by,deleted_on=GETDATE(),is_deleted=1 WHERE pharmacy_id=@id
	 return '1'
  END




GO
/****** Object:  StoredProcedure [dbo].[sp_expired_medication]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Ankit Joshi
-- Create date: 18-04-2018
-- Description: stored procedure to get list of expired medication for inserted pharmacy id
-- exec sp_expired_medication 24,10,1,''
-- =============================================


CREATE PROCEDURE [dbo].[sp_expired_medication]
  @pharmacy_id      INT,
   @PageSize		int,
   @PageNumber      int,
   @SearchString     nvarchar(100)
	AS 
	BEGIN 
	DECLARE @Current_Date DATETIME = GETDATE();
	DECLARE @count INT	
	DECLARE @expiry_month INT = 9;
	SELECT @expiry_month=expiry_month from Inv_Exp_Config

	SELECT @count=ISNULL(COUNT(*),0) FROM inventory 
	WHERE (pharmacy_id =@pharmacy_id AND 
	(EOMONTH(DATEADD(MONTH,@expiry_month,created_on))<GETDATE()) AND 
	ISNULL(is_deleted,0)=0 AND 
	ISNULL(pack_size,0) > 0 and
	(drug_name LIKE '%'+ISNULL(@SearchString,drug_name)+'%')	
	)
	
	SET NOCOUNT ON
		SELECT  
			inventory_id											 AS InventoryId,
			pharmacy_id												 AS PharmacyId,
			wholesaler_id											 AS WholesalerId,
			drug_name												 AS DrugName,
			ndc														 AS NDC,
			pack_size												 AS Quantity,
			price													 AS Price,
			created_on												 AS CreatedOn,
			EOMONTH(DATEADD(MONTH, @expiry_month, ISNULL(created_on,GETDATE()))) AS ExpirtyDate ,
			@count													 AS Count,
			strength												 AS Strength
		FROM [dbo].[inventory] 
		WHERE (
		([pharmacy_id] = @pharmacy_id ) AND
		(ISNULL(is_deleted,0)=0) AND
		(ISNULL(pack_size,0) > 0) AND
		(EOMONTH(DATEADD(MONTH,@expiry_month,created_on))<GETDATE()) and
		(drug_name LIKE '%'+ISNULL(@SearchString,drug_name)+'%')		
		)	
		 ORDER BY inventory_id
		 OFFSET  @PageSize * (@PageNumber - 1)   ROWS
        FETCH NEXT @PageSize ROWS ONLY
END


--exec sp_expired_medication 24,10,1,''



GO
/****** Object:  StoredProcedure [dbo].[SP_get_broadcast_messages]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author: Sagar Sharma     
-- Create date: 18-05-2018
-- Description: SP to GET ALL  broadcast message.
-- =============================================

CREATE PROC [dbo].[SP_get_broadcast_messages]
	
	AS
   BEGIN
		
		SELECT 
			   bmtm.broadcast_message_title_masterid	AS BroadcastTitleId,
			   bmtm.broadcast_message_title				AS BroadcastTitle,
			   bm.broadcast_message_id					AS BroadcastMessageId,
			   bm.message								AS BroadcastMessage,
			   bm.pharmacy_id							AS PharmacyId,
			   pl.pharmacy_name							AS PharmacyName

	     FROM broadcast_message_title_master AS bmtm
		INNER JOIN broadcast_message AS bm ON bmtm.broadcast_message_title_masterid = bm.broadcast_message_title_masterid
		INNER JOIN pharmacy_list AS pl ON bm.pharmacy_id=pl.pharmacy_id


  END




GO
/****** Object:  StoredProcedure [dbo].[SP_get_saPharmacy_by_id]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 27-02-2018
-- Description: SP to Get Pharmacy owner by ID
-- =============================================


 CREATE PROCEDURE [dbo].[SP_get_saPharmacy_by_id]
	(
	@id int
	)
   AS 
	BEGIN
		Select * from sa_pharmacy AS P JOIN sa_superAdmin_sddress AS A ON
		P.pharmacy_id=A.pharmacy_id WHERE
		P.pharmacy_id=@id AND (P.is_deleted <= 0 OR P.is_deleted IS NULL)

	END




GO
/****** Object:  StoredProcedure [dbo].[SP_get_search_Pharmacy]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================
-- Author:      Sagar Sharma
-- Create date: 27-02-2018
-- Description: SP to INSERT or UPDATE the record in pharmacy table
-- =============================================

/*
	EXEC SP_get_search_pharmacy 2, ''
	
*/

CREATE PROCEDURE [dbo].[SP_get_search_Pharmacy]
(  
	@id					INTEGER,
	@pharmacy_name		NVARCHAR(50)
)  
AS  
BEGIN 

	SELECT * FROM pharmacy AS p
		INNER JOIN address_master AS am ON p.pharmacy_id = am.pharmacy_id 
	WHERE (p.pharmacy_name like '%'+@pharmacy_name+'%')  OR (@pharmacy_name = '')
	OR (p.pharmacy_id = @id) OR (@id = 0 )
	AND p.is_deleted = NULL 

END  

 







GO
/****** Object:  StoredProcedure [dbo].[SP_GetShipmentList]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================            
            
-- Create date: 01-03-2019            
-- Created By: Humera Sheikh          
-- Description: SP to show Shipments         
-- EXEC SP_GetShipmentList 13,0,1,''            
-- =============================================            
            
                    
 CREATE PROC [dbo].[SP_GetShipmentList]      
                 
   @pharmacy_id int,      
   @PageSize  int,        
   @PageNumber    int,          
   @SearchString  nvarchar(100)=null         
            
  AS            
            
   BEGIN             
         
   DECLARE @count int;        
   SELECT          
    ship.shippment_id AS ShipmentId,        
    ISNULL(ship.tracking_number,'') AS TrackNumber,           
    ISNULL(ship.purchaser_pharmacy_id,0) AS PurchasePharmacyId,      
    ISNULL(ph.pharmacy_name,'') AS PurchasePharmacyName,             
    ship.order_received AS OrderReceived,        
    ISNULL(shp_md.Name,'UPS') AS ShippingMethod,      
    ISNULL(totalcost,0) AS   TotalCost,      
    ISNULL(ship.shipping_cost,0) AS ShippingCost,      
    COUNT(1) OVER () AS Count                 
   FROM [dbo].[shippment] ship      
   CROSS APPLY (        
    SELECT SUM(quantity *  unit_price) AS TotalCost        
    FROM [dbo].[shippmentdetails] shp_dt         
    WHERE shp_dt.shippment_id = ship.shippment_id       
   ) shp_dt      
   LEFT JOIN [dbo].[pharmacy_list] ph ON ph.pharmacy_id = ship.purchaser_pharmacy_id      
   LEFT JOIN [dbo].[shipping_methods] shp_md ON shp_md.shipping_method_id = ship.shipping_method_id      
   WHERE (ship.seller_pharmacy_id = @pharmacy_id)       
   ORDER BY ShipmentId      
   OFFSET  @PageSize * (@PageNumber - 1)   ROWS        
   FETCH NEXT IIF(@PageSize = 0, 100000, @PageSize) ROWS ONLY        
           
   END 
GO
/****** Object:  StoredProcedure [dbo].[SP_historicalusages]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Sagar Sharma
-- Create date: 23-04-2018
-- Description: SP to calculculate the historical usages(sales count month wise) for a particular drug.
-- Updated date: 04-04-2019
-- Updated By: Prashant Wanjari
-- Description: have to add year condtion its missing now
-- =============================================
	CREATE PROC [dbo].[SP_historicalusages]
	  @inventoryId INT,
	  @pharmacyId INT
	    
		AS
	   BEGIN		
	   DECLARE @ndcCode BIGINT

	  SELECT @ndcCode = ndc from inventory where (inventory_id = @inventoryId and pharmacy_id = @pharmacyId)
	 
	-- find the sales record from Rx30 inventory table on month basis.
	Select SUM(qty_disp) AS salesQty ,DateName(mm,DATEADD(mm,Month(created_on),-1)) as [MonthName],
	ndc,Month(created_on) MON
	into #TempSalesRecord
	from RX30_inventory  where ndc = @ndcCode
	/*Added current year condition.*/
	 AND  (YEAR(getdate()) = YEAR(created_on))
	group by Month(created_on),ndc
	
	select ISNULL(t.salesQty, 0) salesQty, t.[MonthName], ISNULL(t.ndc, 0) ndc, CTE.monthno AS MON
	into #TempSalesRecord1
	from 
	(SELECT 1 as monthno
	 UNION ALL
	 SELECT 2 as monthno
	 UNION ALL
	 SELECT 3 as monthno
	 UNION ALL
	 SELECT 4 as monthno
	 UNION ALL
	 SELECT 5 as monthno
	 UNION ALL
	 SELECT 6 as monthno
	 UNION ALL
	 SELECT 7 as monthno
	 UNION ALL
	 SELECT 8 as monthno
	 UNION ALL
	 SELECT 9 as monthno
	 UNION ALL
	 SELECT 10 as monthno
	 UNION ALL
	 SELECT 11 as monthno
	 UNION ALL
	 SELECT 12 as monthno) AS CTE
	 LEFT JOIN #TempSalesRecord t ON CTE.monthno = t.MON
	

	 -- combine the sales and purchase count month wise and return it.
	 SELECT st.salesQty as salesQty,  st.MonthName as month, st.ndc as ndc , st.MON as monthNo
	 FROM #TempSalesRecord1 as st 


	Drop table #TempSalesRecord
	Drop table #TempSalesRecord1


	
	  END
 -----





--Select * from RX30_inventory  where ndc = 642012590

--Update RX30_inventory set created_on = DATEADD(month, -2, GETDATE()) WHERE rx30_inventory_id = 20080


--select datename(month, '01-Jan-2018')


-- select * from RX30_inventory order by 1 desc 






GO
/****** Object:  StoredProcedure [dbo].[SP_historicalusages_bk_04042019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Sagar Sharma
-- Create date: 23-04-2018
-- Description: SP to calculculate the historical usages(sales count month wise) for a particular drug.
-- =============================================
	CREATE PROC [dbo].[SP_historicalusages_bk_04042019]
	  @inventoryId INT,
	  @pharmacyId INT
	    
		AS
	   BEGIN		
	   DECLARE @ndcCode BIGINT

	  SELECT @ndcCode = ndc from inventory where (inventory_id = @inventoryId and pharmacy_id = @pharmacyId)
	 
	-- find the sales record from Rx30 inventory table on month basis.
	Select SUM(qty_disp) AS salesQty ,DateName(mm,DATEADD(mm,Month(created_on),-1)) as [MonthName],
	ndc,Month(created_on) MON
	into #TempSalesRecord
	from RX30_inventory  where ndc = @ndcCode
	group by Month(created_on),ndc
	
	select ISNULL(t.salesQty, 0) salesQty, t.[MonthName], ISNULL(t.ndc, 0) ndc, CTE.monthno AS MON
	into #TempSalesRecord1
	from 
	(SELECT 1 as monthno
	 UNION ALL
	 SELECT 2 as monthno
	 UNION ALL
	 SELECT 3 as monthno
	 UNION ALL
	 SELECT 4 as monthno
	 UNION ALL
	 SELECT 5 as monthno
	 UNION ALL
	 SELECT 6 as monthno
	 UNION ALL
	 SELECT 7 as monthno
	 UNION ALL
	 SELECT 8 as monthno
	 UNION ALL
	 SELECT 9 as monthno
	 UNION ALL
	 SELECT 10 as monthno
	 UNION ALL
	 SELECT 11 as monthno
	 UNION ALL
	 SELECT 12 as monthno) AS CTE
	 LEFT JOIN #TempSalesRecord t ON CTE.monthno = t.MON
	

	 -- combine the sales and purchase count month wise and return it.
	 SELECT st.salesQty as salesQty,  st.MonthName as month, st.ndc as ndc , st.MON as monthNo
	 FROM #TempSalesRecord1 as st 


	Drop table #TempSalesRecord
	Drop table #TempSalesRecord1


	
	  END
 -----





--Select * from RX30_inventory  where ndc = 642012590

--Update RX30_inventory set created_on = DATEADD(month, -2, GETDATE()) WHERE rx30_inventory_id = 20080


--select datename(month, '01-Jan-2018')


-- select * from RX30_inventory order by 1 desc 






GO
/****** Object:  StoredProcedure [dbo].[SP_insert_CSVImport_BatchDetails]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE PROCEDURE [dbo].[SP_insert_CSVImport_BatchDetails]
(  
	@id					INTEGER,
	@pharmacy_id		INTEGER,  
	@wholealer_id       INTEGER,  
	@created_by		    INTEGER,  
	@file_name          NVARCHAR(500),  
	@isSuccess          BIT,  
	@isError            BIT,
	@no_of_records		INT
	)  
AS  
BEGIN  
 
   IF ISNULL(@id,0)=0
	  BEGIN
			INSERT INTO wholesaler_csvimport_batch_master(
			pharmacy_id,wholesaler_id,importdate,created_on,created_by)
			VALUES(@pharmacy_id, @wholealer_id, GETDATE(),GETDATE(), @created_by)  

			DECLARE @csvimport_id int;
			set  @csvimport_id = (SELECT @@IDENTITY);

			INSERT INTO wholesaler_csvimport_batch_details(csvimport_batch_id,filename,is_success,is_error,no_of_records,created_on,created_by)
			VALUES (@csvimport_id,@file_name,@isSuccess,@isError,@no_of_records,GETDATE(),@created_by)

			SELECT TOP 1 * FROM wholesaler_csvimport_batch_master ORDER BY csvimport_batch_id desc
	 END
	 ELSE
		BEGIN 
			 UPDATE wholesaler_csvimport_batch_master
			 SET pharmacy_id=@pharmacy_id,wholesaler_id=@wholealer_id,updated_on=GETDATE(),updated_by=@created_by
			 where csvimport_batch_id=@id

			 UPDATE wholesaler_csvimport_batch_details 
			 SET filename=@file_name,is_success=@isSuccess,is_error=@isError,no_of_records=@no_of_records,updated_on=GETDATE(),updated_by=@created_by
			 where csvimport_batch_id=@id

			SELECT TOP 1 * FROM wholesaler_csvimport_batch_master ORDER BY csvimport_batch_id desc
	
	 END
END  




GO
/****** Object:  StoredProcedure [dbo].[SP_insert_order_pre_shipping]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE PROCEDURE [dbo].[SP_insert_order_pre_shipping]

(  

	@transferMgmtId         INTEGER,

	@mpPostitemId			INTEGER,

	@seller_pharmacy_id		INTEGER,  

	@purchaser_pharmacy_id	INTEGER,

	@quantity				INTEGER,
	@shipping_method_id			INTEGER /*Added for Shipping Method*/

)  

AS  

	BEGIN  

	INSERT INTO pre_shippmentorder(

		mp_postitem_id, quantity,  purchaser_pharmacy_id, seller_pharmacy_id, created_on, created_by, is_deletd,shipping_status_master_id,shipping_method_id	 )

	 VALUES

		(

		 @mpPostitemId,

		 @quantity,

		 @purchaser_pharmacy_id,

		 @seller_pharmacy_id,

		 GETDATE(),

		 @seller_pharmacy_id,

		 0,

		 1,

		 @shipping_method_id /*Added for Shipping Method*/
		 )  


		 UPDATE transfer_management set 
				is_deletd = 1,
				deleted_on = GETDATE()
		 WHERE transfer_mgmt_id	= @transferMgmtId



	END  


GO
/****** Object:  StoredProcedure [dbo].[SP_insert_order_pre_shipping_bk_05/02/2019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE PROCEDURE [dbo].[SP_insert_order_pre_shipping_bk_05/02/2019]

(  

	@transferMgmtId         INTEGER,

	@mpPostitemId			INTEGER,

	@seller_pharmacy_id		INTEGER,  

	@purchaser_pharmacy_id	INTEGER,

	@quantity				INTEGER


)  

AS  

	BEGIN  

	INSERT INTO pre_shippmentorder(

		mp_postitem_id, quantity,  purchaser_pharmacy_id, seller_pharmacy_id, created_on, created_by, is_deletd,shipping_status_master_id	 )

	 VALUES

		(

		 @mpPostitemId,

		 @quantity,

		 @purchaser_pharmacy_id,

		 @seller_pharmacy_id,

		 GETDATE(),

		 @seller_pharmacy_id,

		 0,

		 1
		 )  


		 UPDATE transfer_management set 
				is_deletd = 1,
				deleted_on = GETDATE()
		 WHERE transfer_mgmt_id	= @transferMgmtId






	END  

GO
/****** Object:  StoredProcedure [dbo].[SP_insert_transfermgmt_marketplace]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

--==============================================
-- Create date: 07-05-2018
-- Description: SP to INSERT the transfer management market place.
-- =============================================


CREATE PROCEDURE [dbo].[SP_insert_transfermgmt_marketplace]
(  
	@mp_postitem_id         INTEGER,
	@sellerpharmacy_id		INTEGER,  
	@purchaser_pharmacy_id	INTEGER,
	@updated_qty			INTEGER
	
)  
AS  
	BEGIN  
    DECLARE @Transfer_Mgt_id_identity  INT
	INSERT INTO transfer_management(
		  mp_postitem_id, seller_pharmacy_id, purchaser_pharmacy_id, updated_quantity, created_on, created_by,is_deletd)
	 VALUES(
		 @mp_postitem_id,
		 @sellerpharmacy_id,
		 @purchaser_pharmacy_id,
		 @updated_qty,
		 GETDATE(),
		 @purchaser_pharmacy_id,
		 0) 
		  
		   --By Humera
		 	/*here we are adding details to market place drug purchase notification table for displaying the notification  */		
		Select @Transfer_Mgt_id_identity  =	 @@Identity;

		INSERT INTO marketplace_drugpurchase_notification(Transfer_Mgt_Id, mp_postitem_id, sellerpharmacy_id,purchaser_pharmacy_id, is_read, message, created_by, created_on)

		(SELECT @Transfer_Mgt_id_identity, @mp_postitem_id,@sellerpharmacy_id,@purchaser_pharmacy_id, 0, '', @purchaser_pharmacy_id, GETDATE()  

			FROM transfer_management WHERE is_deletd = 0 AND purchaser_pharmacy_id = @purchaser_pharmacy_id AND seller_pharmacy_id = @sellerpharmacy_id)

	END  


--select * from transfer_management



GO
/****** Object:  StoredProcedure [dbo].[SP_insert_transfermgmt_marketplace_bk_05/02/2019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

--==============================================
-- Create date: 07-05-2018
-- Description: SP to INSERT the transfer management market place.
-- =============================================


CREATE PROCEDURE [dbo].[SP_insert_transfermgmt_marketplace_bk_05/02/2019]
(  
	@mp_postitem_id         INTEGER,
	@sellerpharmacy_id		INTEGER,  
	@purchaser_pharmacy_id	INTEGER,
	@updated_qty			INTEGER
	
)  
AS  
	BEGIN  
	INSERT INTO transfer_management(
		  mp_postitem_id, seller_pharmacy_id, purchaser_pharmacy_id, updated_quantity, created_on, created_by,is_deletd)
	 VALUES(
		 @mp_postitem_id,
		 @sellerpharmacy_id,
		 @purchaser_pharmacy_id,
		 @updated_qty,
		 GETDATE(),
		 @purchaser_pharmacy_id,
		 0)  
	END  


--select * from transfer_management



GO
/****** Object:  StoredProcedure [dbo].[SP_insert_update_drug_in_marketplace]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
--==============================================
-- Created by : Sagar Sharma
-- Create date: 29-03-2018
-- Description: SP to INSERT or UPDATE the the drug in market place.
-- =============================================


CREATE PROCEDURE [dbo].[SP_insert_update_drug_in_marketplace]
(  
	@mp_postitem_id         INTEGER,
	@mp_network_type_id		INTEGER,  
	@pharmacy_id			INTEGER,
	@drug_name				NVARCHAR(1000),  
	@ndc_code				BIGINT,
	@pack_size				DECIMAL(18,2),
	@strength				NVARCHAR(500),
	@base_price				MONEY,
	@sales_price			MONEY,
	@lot_number				NVARCHAR(100),
	@expiry_date			DATETIME,  
	@created_by				INTEGER
)  
AS  
BEGIN  
IF ISNULL(@mp_postitem_id,0) = 0 
	BEGIN  

		DECLARE @mp_postitem_id_identity  INT

	INSERT INTO mp_post_items(
		 mp_network_type_id, pharmacy_id, drug_name, ndc_code, pack_size, strength, base_price, sales_price,lot_number, exipry_date, created_on, created_by)
	 VALUES(
		 @mp_network_type_id,
		 @pharmacy_id,
		 @drug_name,
		 @ndc_code,
		 @pack_size,
		 @strength,
		 @base_price,
		 @sales_price,
		 @lot_number,
		 @expiry_date,
		 GETDATE(),
		 @created_by)  

		 Select @mp_postitem_id_identity  =	 @@Identity;

		 	/*here we are adding details to market place drug posting notification table for displaying the notification  */		

		INSERT INTO marketplace_drugpost_notification(mp_postitem_id, pharmacy_id, is_read, message, created_by, created_on)

		(SELECT @mp_postitem_id_identity, sister_pharmacy_id, 0, '', @pharmacy_id, GETDATE()  

			FROM sister_pharmacy_mapping WHERE is_deleted = 0 AND parent_pharmacy_id = @pharmacy_id)



	END  
 
ELSE
	BEGIN  
	UPDATE mp_post_items SET  
		mp_network_type_id	=		@mp_network_type_id,
		pharmacy_id			=		@pharmacy_id,
		drug_name			=		@drug_name,
		ndc_code			=		@ndc_code,
		pack_size			=		@pack_size,
		strength			=		@strength,
		base_price			=		@base_price,
		sales_price			=		@sales_price,
		lot_number			=		@lot_number,
		exipry_date			=		@expiry_date,
		updated_on			=		GETDATE(),
		updated_by			=		@created_by
		  
	WHERE mp_postitem_id    =		@mp_postitem_id
	END  
  
END



GO
/****** Object:  StoredProcedure [dbo].[SP_Insert_update_Inventory]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 04-04-2018
-- Description: SP to Add/Update Inventory

-- =============================================

CREATE PROCEDURE [dbo].[SP_Insert_update_Inventory]
	(
	@id					int,
	@pharmacyid			int,
	@wholesalerid		int,
	@drugname			nvarchar(200),
	@ndc				Bigint,
	@genericcode		Bigint,
	@packsize			decimal(10,2),	
	@created_by			int,	
	@price				money,
	@opened				bit,
	@damage				bit,
	
	@non_c2				bit,
	@lotNumber			nvarchar(100),
	@expirydate			datetime,
	@strength			nvarchar(100),
	@ndc_PackSize		decimal(10,2)
	)
 AS 
 BEGIN
    DECLARE @expired_month INT
	DECLARE @partialdate DATETIME
	SELECT @expired_month = [expiry_month] FROM [Inv_Exp_Config]
 SET NOCOUNT ON;
	IF(EXISTS(SELECT inv.ndc FROM inventory inv WHERE inv.ndc = @ndc AND inv.inventory_id=@id))
	BEGIN
	
	SELECT @partialdate=created_on FROM inventory WHERE inventory_id=@id

		IF(FORMAT( @expirydate, 'dd/MM/yyyy')= FORMAT(@partialdate,'dd/MM/yyyy'))
		SET @expirydate=@expirydate
		ELSE
		SET @expirydate = (DATEADD(month, - @expired_month, @expirydate))



		UPDATE [dbo].[inventory] SET 
			pharmacy_id=@pharmacyid,		
			drug_name=@drugname, 
			ndc=@ndc,
			price=@price,
			updated_on=GETDATE(), 
			updated_by=@created_by,
			damaged=@damage,
			opened =@opened,
			non_c2=@non_c2,
			pack_size=@packsize,
			LotNumber=@lotNumber,
			created_on=@expirydate			
			where inventory_id = @id
	END
	ELSE
	BEGIN
	
	IF(FORMAT( GETDATE(), 'dd/MM/yyyy')= FORMAT(@expirydate,'dd/MM/yyyy'))
	SET @expirydate = @expirydate	
	ELSE
	SET @expirydate = (DATEADD(month, - @expired_month, @expirydate))

		  INSERT INTO [dbo].[inventory](pharmacy_id,wholesaler_id,drug_name,ndc,generic_code, pack_size,price,created_on, created_by, is_deleted,
		  Strength,NDC_Packsize,LotNumber,opened,non_c2,damaged)
		   VALUES
		  (@pharmacyid,@wholesalerid,@drugname,@ndc,@genericcode,@packsize,@price,@expirydate,@created_by,0,@strength,@ndc_PackSize,@lotNumber,@opened,@non_c2,@damage)
		
	END

	SET NOCOUNT OFF;
END;


--select * from inventory where ndc=1439284  and is_deleted=0 and pharmacy_id=11
GO
/****** Object:  StoredProcedure [dbo].[SP_insert_update_medicine]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- Create date: 29-03-2018
-- Description: SP to INSERT or UPDATE the record in Inventory table (Add Medicine)
-- Modified by : Sagar Sharma on 02-04-2018
-- =============================================



CREATE PROCEDURE [dbo].[SP_insert_update_medicine]
(  
	@medicineid         INTEGER,
	@pharmacy_id	    INTEGER,  
	@drug_name			NVARCHAR(1000),  
	@ndc_code           BIGINT,  
	@generic_code       BIGINT,  
	@description		NVARCHAR(1000),
	@created_by			INTEGER
)  
AS  
BEGIN  
IF ISNULL(@medicineid,0) = 0 
	BEGIN  
	INSERT INTO medicine(
		 pharmacy_id,drug_name, ndc_code, generic_code, description, created_on, created_by)
	 VALUES(
		 @pharmacy_id, @drug_name, @ndc_code, @generic_code, @description,  GETDATE(), @created_by)  
	END  
 
ELSE
	BEGIN  
	UPDATE medicine SET  
		pharmacy_id = @pharmacy_id,
		drug_name = @drug_name,
		ndc_code= @ndc_code,
		generic_code = @generic_code,
		description = @description,
		updated_on = GETDATE(),
		updated_by = @created_by
		  
	WHERE medicine_id  = @medicineid
	END  
  
END



GO
/****** Object:  StoredProcedure [dbo].[SP_insert_update_notificationSetting]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[SP_insert_update_notificationSetting]
	(
	
	@message			bit,
	@email				bit,
	@phone		        bit,
	@pharmacy_id		int,
	@created_by			int
	)
 AS 
 BEGIN 
 SET NOCOUNT ON;
	
	   DECLARE @isPresent int = 0;
	   SET  @isPresent = (select count(*) from [dbo].[pharmacy_notification_setting] where  pharmacy_id=@pharmacy_id)
		
	IF(@isPresent=0)

		BEGIN
			INSERT INTO [dbo].[pharmacy_notification_setting] (pharmacy_id,is_hide_read_messages,is_notify_me_on_mail,is_notify_me_on_phone,created_by,created_on,is_deleted)
			VALUES (@pharmacy_id,@message,@email,@phone,@created_by,GETDATE(),0)
		END

	ELSE
		BEGIN
			 UPDATE [dbo].[pharmacy_notification_setting] SET is_hide_read_messages=@message,is_notify_me_on_mail=@email,
			 is_notify_me_on_phone=@phone,updated_by=@created_by,updated_on=GETDATE() where pharmacy_id=@pharmacy_id
		END
	SET NOCOUNT OFF;
END;






GO
/****** Object:  StoredProcedure [dbo].[SP_insert_update_order]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================
-- Author:      Sagar Sharma
-- Create date: 02-04-2018
-- Description: SP to INSERT or UPDATE the Order for a pharmacy
-- =============================================

CREATE PROCEDURE [dbo].[SP_insert_update_order]
	(
	@orderId			int,
	@pharmacyId			int,
	@wholesalerId		int,
	@orderstatusId		int,
	@created_by			int
	)
 AS 
 BEGIN
 DECLARE @order_id INT

 SET NOCOUNT ON;
	 IF(@orderId = 0)
	  BEGIN
		
		  INSERT INTO orders(pharmacy_id, wholesaler_id, order_status_id, created_on, created_by, is_deleted)
		   VALUES
		  (@pharmacyId, @wholesalerId, @orderstatusId, GETDATE(), @created_by,0);
		  
			SET  @order_id = (SELECT @@IDENTITY); 
		
	   END 
	ELSE 
		BEGIN
			UPDATE orders SET 
			pharmacy_id = @pharmacyId,
			wholesaler_id = @wholesalerId, 
			order_status_id = @orderstatusId, 
			updated_on=GETDATE(),
			updated_by=@created_by
			WHERE order_id = @orderId

			SET  @order_id = @orderId;
	END

			--return the id of new created order and return 0 if order id updated.
			select Top 1 * From orders where order_id = @order_id;

	SET NOCOUNT OFF;
END;




GO
/****** Object:  StoredProcedure [dbo].[SP_insert_update_orderdetails]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO






-- =============================================
-- Author:      Sagar Sharma
-- Create date: 02-04-2018
-- Description: SP to INSERT or UPDATE the Order Details for a pharmacy
-- =============================================


CREATE PROCEDURE [dbo].[SP_insert_update_orderdetails]

	@orderDetailsId			int,

	@orderId				int,

	@drugname				NVARCHAR(1000),

	@ndc					BIGINT,

	@quantity_packsize		DECIMAL(10,2),
	
	@created_by				int,

	@price					MONEY,

	@opened					BIT,

	@damage					BIT,

	@non_c2					BIT,

	@lotNumber				NVARCHAR(500),

	@expirydate				DATETIME,

	@strength				NVARCHAR(500),

	@ndc_PackSize			DECIMAL(10,2)

	

 AS 

 BEGIN

 SET NOCOUNT ON;

	 IF(@orderDetailsId > 0)

	  BEGIN

		  DELETE  FROM order_details WHERE	 order_details_id = @orderDetailsId;

	   END 

	INSERT INTO order_details(order_id, drugname, ndc, price, quantity, ndc_packsize, damaged, non_c2, opened, expiry_date, lot_number, strength, created_on , created_by, is_deleted )

		   VALUES

		  (@orderId, @drugname, @ndc, @price, @quantity_packsize, @ndc_PackSize, @damage, @non_c2, @opened, @expirydate, @lotNumber, @strength, GETDATE(), @created_by, 0);

	SET NOCOUNT OFF;

	

END;












GO
/****** Object:  StoredProcedure [dbo].[SP_insert_update_pharmacy]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
--USE [inviewanalytics]

-- =============================================
-- Author:      Sagar Sharma
-- Create date: 27-02-2018
-- Description: SP to INSERT or UPDATE the record in pharmacy table
-- =============================================

/*
	EXEC SP_insert_update_pharmacy 1, "Pharmcay4", "lic123", "tax123", "Notes", "rijal@yopmail.com",
		"2018-02-27 10:48:40.633",1,
		"2018-02-27 10:48:40.633",1, 
		"2018-02-27 10:48:40.633",1,0

*/

CREATE PROCEDURE [dbo].[SP_insert_update_pharmacy]
(  
	@pharmacy_id		INTEGER,  
	@pharmacy_name      NVARCHAR(1000),  
	@license_number     NVARCHAR(1000),  
	@tax_id             NVARCHAR(1000),  
	@notes              NVARCHAR(max),  
	@email              NVARCHAR(1000),
	@created_on			DATETIME,
	@created_by			INTEGER,
	@updated_on			DATETIME,
	@updated_by			INTEGER,
	@deleted_on			DATETIME,
	@deleted_by			INTEGER,
	@is_deleted			BIT

)  
AS  
BEGIN  
IF ISNULL(@pharmacy_id,0) = 0 
	BEGIN  
	INSERT INTO pharmacy(
		 pharmacy_name, license_number, tax_id, notes, email, created_on, created_by)
	 VALUES(
		 @pharmacy_name, @license_number, @tax_id, @notes, @email, GETDATE(), @created_by)  
	END  
 
ELSE
	BEGIN  
	UPDATE pharmacy SET  
		pharmacy_name = @pharmacy_name,
		license_number = @license_number,
		tax_id= @tax_id,
		notes = @notes,
		email = @email,		
		updated_on = GETDATE(),
		updated_by = @updated_by
		  
	WHERE  pharmacy_id = @pharmacy_id 
	END  
  
END






GO
/****** Object:  StoredProcedure [dbo].[SP_insert_update_pharmacy_business_profile]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:		Prashant Wanjari
-- Create date: 23/03/2018
-- Description:	Add/Update bussiness details of Pharmacy
-- =============================================
CREATE PROCEDURE [dbo].[SP_insert_update_pharmacy_business_profile] 
	(
		@business_profile_id	INT,
		@pharmacy_id			INT,
		@business_address		NVARCHAR(MAX),
		@business_contact		NVARCHAR(MAX),
		@logo					NVARCHAR(1000),
		@created_by				INT
	)

AS
BEGIN
	
	SET NOCOUNT ON;
	 IF(@business_profile_id = 0)
	 BEGIN
		INSERT INTO pharmacy_business_profile(
				[pharmacy_id],
				[business_address],
				[business_contact],
				[logo],
				[created_on],
				[created_by], 
				[is_deleted]
			)
			VALUES(
				@pharmacy_id,
				@business_address,
				@business_contact,
				@logo,
				GETDATE(),
				@created_by,
				0
			)
	 END
	 ELSE
	 BEGIN
		UPDATE pharmacy_business_profile SET
			business_address = @business_address,
			business_contact = @business_contact,
			logo = @logo,
			updated_on = GETDATE(),
			updated_by = @created_by
		WHERE
			business_profile_id = @business_profile_id;

	 END
    
END




GO
/****** Object:  StoredProcedure [dbo].[SP_insert_update_pharmacy_report_logo]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:		Sagar Sharma
-- Create date: 24/03/2018
-- Description:	Add/Update Report logo of Pharmacy
-- =============================================
CREATE PROCEDURE [dbo].[SP_insert_update_pharmacy_report_logo] 
	(
		@pharmacy_report_setting_id 	INT,
		@pharmacy_id					INT,
		@logo							NVARCHAR(1000),
		@created_by						INT
	)

AS
BEGIN
	
	SET NOCOUNT ON;
	 IF(@pharmacy_report_setting_id = 0)
	 BEGIN
		INSERT INTO pharmacy_report_setting(
				[pharmacy_id],
				[logo],
				[created_on],
				[created_by]
			)
			VALUES(
				@pharmacy_id,
				@logo,
				GETDATE(),
				@created_by
			)
	 END
	 ELSE
	 BEGIN
		UPDATE pharmacy_report_setting SET
			logo = @logo,
			updated_on = GETDATE(),
			updated_by = @created_by 
			WHERE pharmacy_reprot_setting_id = @pharmacy_report_setting_id;
	 END
    
END




GO
/****** Object:  StoredProcedure [dbo].[SP_insert_update_pharmacyOwner]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 27-02-2018
-- Description: SP to INSERT or UPDATE the record in sa_pharmacy_owner table
-- =============================================

CREATE PROCEDURE [dbo].[SP_insert_update_pharmacyOwner]
		(
		@id				int,
		@f_name			nvarchar(50),
		@m_name			nvarchar(50),
		@l_name			nvarchar(50),
		@gender			int,
		@contact_no		nvarchar(100),
		@dob			datetime =null,
		@pharmacy_name  nvarchar(200),
		@email			nvarchar(50),
		@created_by		int,
		@address1		nvarchar(100),
		@address2		nvarchar(100),
		@country_id		int,
		@state_id		int,
		@city			nvarchar(100),
		@zipcode		nvarchar(10)
		

		)
 AS 

-- If @dob=''
 --set @dob=null
	IF(@id = 0)
	
	 BEGIN
		 INSERT	into sa_pharmacy_owner(first_name,last_name,middle_name,pharmacy_name,gender,contact_no,email,dob,created_on,created_by,is_deleted)
		 VALUES (@f_name,@l_name,@m_name,@pharmacy_name,@gender,@contact_no,@email,@dob,GETDATE(),@created_by,0)
 
		 DECLARE @ph_id int;
		 set  @ph_id = (SELECT @@IDENTITY);
		    
		INSERT into sa_superAdmin_sddress(pharmacy_owner_id,address_line_1,address_line_2,country_id,state_id,
		city,zipcode,created_on,created_by,is_deleted) VALUES (@ph_id,@address1,@address2,@country_id,@state_id,@city,
		@zipcode,GETDATE(),@created_by,0)
	END

	ELSE 
	 BEGIN
		UPDATE sa_pharmacy_owner SET first_name=@f_name,middle_name=@m_name,last_name=@l_name,pharmacy_name=@pharmacy_name,gender=@gender,contact_no=@contact_no,
		email=@email,dob=@dob,updated_on=GETDATE(),updated_by=@created_by where pharmacy_owner_id=@id

		UPDATE sa_superAdmin_sddress SET address_line_1=@address1,address_line_2=@address2,country_id=@country_id,state_id=@state_id,
		city=@city,zipcode=@zipcode,updated_on=GETDATE(),updated_by=@created_by where pharmacy_Owner_id=@id

	END





GO
/****** Object:  StoredProcedure [dbo].[SP_Insert_update_pharmacyUser]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 22-03-2018
-- Description: SP to Add/Update pharmacy user
-- =============================================

CREATE PROCEDURE [dbo].[SP_Insert_update_pharmacyUser]
	(
	@id					int,
	@pharmacyid			int,
	@fname				nvarchar(50),
	@mname				nvarchar(50),
	@lname				nvarchar(50),
	@email				nvarchar(50),	
	@created_by			int,	
	@address1			nvarchar(400),
	@address2			nvarchar(400),
	@country_id			int,
	@state_id			int,
	@city			nvarchar(150),
	@zipcode			nvarchar(10),
	@phone				nvarchar(20)
	)
 AS 
 BEGIN

 SET NOCOUNT ON;
	 IF(@id = 0)
	  BEGIN
		
		
		  INSERT INTO [dbo].[pharmacy_users](pharmacy_id,first_name,middle_name,last_name,email, created_on, created_by, is_deleted)
		   VALUES
		  (@pharmacyid,@fname,@mname,@lname,@email,GETDATE(),@created_by,0)
		
			DECLARE @user_id int;
			set  @user_id = (SELECT @@IDENTITY);

			INSERT into [dbo].[address_master](pharmacy_user_id, address_line1, address_line2, country_id, state_id,
			city, zipcode, phone, created_on, created_by, is_deleted)
			VALUES 
			(@user_id, @address1, @address2, @country_id, @state_id, @city, @zipcode, @phone, GETDATE(), @created_by,0)
			
	   END 
	ELSE 
		BEGIN
			UPDATE [dbo].[pharmacy_users] SET 
			first_name=@fname,middle_name=@mname,last_name=@lname, email=@email, updated_on=GETDATE(), updated_by=@created_by where pharmacy_user_id = @id

			UPDATE [dbo].[address_master] SET 
			address_line1=@address1,address_line2=@address2, country_id=@country_id, state_id=@state_id,
			city=@city, zipcode=@zipcode, phone=@phone, updated_on=GETDATE(),updated_by=@created_by where pharmacy_user_id = @id
	END

	SET NOCOUNT OFF;
END;






GO
/****** Object:  StoredProcedure [dbo].[SP_Insert_update_pharmacyUserRole]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[SP_Insert_update_pharmacyUserRole]
	(
	@id						int,
	@pharmacyuserid			int,
	@pharmacyroleid			int,
	@username				nvarchar(50),
	@password				nvarchar(50),	
	@created_by				int	
	
	)
 AS 
 BEGIN

 SET NOCOUNT ON;
	  IF(@id = 0)
	  BEGIN
		
		UPDATE [dbo].[pharmacy_users] SET username = @username, password = @password,updated_by=@created_by,updated_on=GETDATE()
		WHERE pharmacy_user_id=@pharmacyuserid AND is_deleted=0;
	 
		INSERT into [dbo].[pharmacy_users_roles_assignment](pharmacy_user_id, pharmacy_user_role_id,created_on, created_by, is_deleted)
		VALUES (@pharmacyuserid, @pharmacyroleid, GETDATE(),@created_by,0)
			
	   END 
	ELSE
	BEGIN
	UPDATE [dbo].[pharmacy_users] SET username = @username, password = @password,updated_by=@created_by,updated_on=GETDATE()
		WHERE pharmacy_user_id=@pharmacyuserid AND is_deleted=0;

	UPDATE [dbo].[pharmacy_users_roles_assignment] SET pharmacy_user_id=@pharmacyuserid,pharmacy_user_role_id=@pharmacyroleid,
	updated_by=@created_by, updated_on=GETDATE(),is_deleted=0,deleted_by=null,deleted_on=null where pharmacy_user_roles_assignment_id=@id
	END

	SET NOCOUNT OFF;
END;



GO
/****** Object:  StoredProcedure [dbo].[SP_insert_update_returnalert]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- Description: SP to INSERT or UPDATE the record in Returnalert table (Returns)

-- =============================================


CREATE PROCEDURE [dbo].[SP_insert_update_returnalert]
(  
	  
	@pharmacy_id	   INTEGER,  
	@alert_date        DATETIME,
	@druginventoryid   INTEGER,
	@description       NVARCHAR(2000),
	@is_read			BIT
  
)  
  AS  
  BEGIN
  IF(@is_read =0)
	BEGIN	
	INSERT INTO returnalert(
		 pharmacy_id, alert_date,created_on, created_by,description,drug_InventoryId,is_read)
	 VALUES(
		  @pharmacy_id,@alert_date ,GETDATE(), @pharmacy_id,@description,@druginventoryid,@is_read)
    END   
  END


 


GO
/****** Object:  StoredProcedure [dbo].[SP_insert_update_returntowholesaler]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 17-04-2018
-- Description: SP to INSERT or UPDATE the Return To wholesaler
-- =============================================

CREATE PROCEDURE [dbo].[SP_insert_update_returntowholesaler]
	(
	@pharmacy_id	      bigint,
	@created_by			  int
	
	)
 AS 
 BEGIN

 SET NOCOUNT ON;
	DECLARE @return_id INT=0
	  BEGIN
		
		  INSERT INTO ReturnToWholesaler( pharmacy_id,created_on, created_by, is_deleted)
		   VALUES
		  ( @pharmacy_id, GETDATE(), @created_by,0);
		  
			SET  @return_id = (SELECT @@IDENTITY); 
		  END 

			select Top 1 * From ReturnToWholesaler where returntowholesaler_id = @return_id;

	SET NOCOUNT OFF;
END;


--select * from [dbo].[ReturnToWholesaler]
--exec SP_insert_update_returntowholesaler 0,1,1



GO
/****** Object:  StoredProcedure [dbo].[SP_insert_update_returntowholesaleritem]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

 -- =============================================
-- Author:      Priyanka Chandak
-- Modified By : Sagar Sharma on 24-04-2018
-- Create date: 017-04-2018
-- Description: SP to save the return item to a wholesaler from return to wholesaler amount list.
-- =============================================

CREATE PROCEDURE [dbo].[SP_insert_update_returntowholesaleritem]
	(
	@itemId						BIGINT,
	@returntowholesalerid		BIGINT,
	@inventoryid				BIGINT,
	@drugname					NVARCHAR(150),
	@wholesalername				NVARCHAR(150),
	@ndc						BIGINT,
	@quantity					DECIMAL(10,2),
	@amount						MONEY,
	@expirydate					DATETIME,
	@lotno						NVARCHAR(150),
	@wholesalerid				INT,
	@created_by					INT
	
	)
 AS 
 BEGIN
	INSERT INTO [dbo].[return_to_wholesaler_items](
			returntowholesaler_Id,
			inventory_id,
			drug_name,
			wholesaler_name,
			ndc,
			quantity,
			amount,
			expiry_date,
			lot_number,
			wholesaler_id, 
			created_on,
			created_by, 
			is_deleted)

		   VALUES
		    ( 
		   @returntowholesalerid, 
		   @inventoryid,
		   @drugname,
		   @wholesalername,
		   @ndc,
		   @quantity,
		   @amount,
		   @expirydate,
		   @lotno,
		   @wholesalerid,
		   GETDATE(), 
		   @created_by, 
		   0);

	DECLARE @pharmacy_id  INT

	SELECT @pharmacy_id =pharmacy_id from ReturnToWholesaler where returntowholesaler_Id =@returntowholesalerid

	--SP to substract the qty from inventory table with respect to ndc and pharmacy id
	EXEC substract_qty_from_inventory @pharmacy_id,@quantity,@ndc

		
END

--SELECT * FROM return_to_wholesaler_items
--exec SP_insert_update_returntowholesaleritem 0,1,2123,1




GO
/****** Object:  StoredProcedure [dbo].[SP_insert_update_rx30batchdetails]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================
-- Author:      Sagar Sharma
-- Create date: 10-04-2018
-- Description: SP to INSERT data in Rx30 batch details table.
-- =============================================

CREATE PROCEDURE [dbo].[SP_insert_update_rx30batchdetails]
	(
	@id								int,
	@batchmasterid					int,
	@filename						nvarchar(100),
	@issuccess						bit,
	@iserror						bit,
	@noofrecords					int
	)
 AS 
 BEGIN
 DECLARE @rx30batchdetailsID int;
	 IF(@id = 0)
	  BEGIN
		
		  INSERT INTO rx30_batch_details(rx30_batch_id, filename, is_success, is_error, no_of_records, created_on, is_deleted)
		   VALUES
		  (@batchmasterid, @filename, @issuccess, @iserror, @noofrecords, GETDATE(),0) 
		
			
			set  @rx30batchdetailsID = (SELECT @@IDENTITY);
			
	   END 
	ELSE 
		BEGIN
			UPDATE rx30_batch_details SET 
			rx30_batch_id=		@batchmasterid,
			filename=			@filename, 
			is_success=			@issuccess, 
			is_error=			@iserror, 
			no_of_records=		@noofrecords,
			updated_on=			GETDATE()
			where 
			rx30_batch_details_id  =		@id

			set  @rx30batchdetailsID = @id ;
	END

	Select @rx30batchdetailsID as Rx30BatchDetailsId;

END;




GO
/****** Object:  StoredProcedure [dbo].[SP_insert_update_rx30batchmaster]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================
-- Author:      Sagar Sharma
-- Create date: 10-04-2018
-- Description: SP to INSERT data in Rx30 batch master table.
-- =============================================

CREATE PROCEDURE [dbo].[SP_insert_update_rx30batchmaster]
	(
	@id					int,
	@pharmacyid			int,
	@directorypath		nvarchar(500),
	@nooffiles			int,	
	@pharmacyname		nvarchar(400)
	
	)
 AS 
 BEGIN
 DECLARE @rx30batchID int;
	 IF(@id = 0)
	  BEGIN
		
		  INSERT INTO rx30_batch_master(pharmacy_id, no_of_files, pharmacy_name, directory_path, created_on, is_deleted)
		   VALUES
		  (@pharmacyid, @nooffiles, @pharmacyname, @directorypath, GETDATE(),0) 
		
			set  @rx30batchID = (SELECT @@IDENTITY);
			
	   END 
	ELSE 
		BEGIN
			UPDATE rx30_batch_master SET 
			pharmacy_id=		@pharmacyId,
			no_of_files=		@nooffiles, 
			pharmacy_name=		@pharmacyname, 
			directory_path=		@directorypath, 
			updated_on=			GETDATE()
			where 
			rx30_batch_id =		@id

			set  @rx30batchID = @id ;
	END

	select @rx30batchID as Rx30BatchId;

END;




GO
/****** Object:  StoredProcedure [dbo].[SP_insert_update_sa_pharmacy]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO








CREATE PROCEDURE [dbo].[SP_insert_update_sa_pharmacy]
	(
	@id					int,
	@pharmacy_name		nvarchar(90),
	@pharmacy_ownerid	int,
	@pharmacy_logo		nvarchar(100),
	@registration_date	datetime,
	@subscriptionplanid int,
	@subscription_status nvarchar(50),
	@contact_no			 nvarchar(50),
	@mobile_no			 nvarchar(50),
	@created_by			 int,	
	@address1			 nvarchar(400),
	@address2			 nvarchar(400),
	@country_id			 int,
	@state_id			 int,
	@city				 nvarchar(100),
	@zipcode			 nvarchar(10),
	@email				 nvarchar(100)
	
	)

 AS 
 BEGIN
 DECLARE @ph_id int;
 SET NOCOUNT ON;
 	 IF(@id = 0)
	  BEGIN
		 begin try
		  INSERT INTO pharmacy_list(pharmacy_name,pharmacy_owner_id,pharmacy_logo,registrationdate,subscription_plan_id
		  ,subscription_status,contact_no,mobile_no,created_by,created_on,is_deleted,Email) VALUES (@pharmacy_name,@pharmacy_ownerid,
		  @pharmacy_logo,@registration_date,@subscriptionplanid,@subscription_status,@contact_no,@mobile_no,@created_by,GETDATE(),0,@email)
		  set  @ph_id = (SELECT @@IDENTITY);

		  INSERT into sa_superAdmin_sddress(pharmacy_id,address_line_1,address_line_2,country_id,state_id,
		  city,zipcode,created_on,created_by,is_deleted) VALUES (@ph_id,@address1,@address2,@country_id,@state_id,@city,
		  @zipcode,GETDATE(),@created_by,0)


	 end try
	  begin catch
	   end catch
	    END 
   ELSE 
   		BEGIN

		UPDATE pharmacy_list SET 
	    pharmacy_name=@pharmacy_name,pharmacy_owner_id=@pharmacy_ownerid,registrationdate=@registration_date,subscription_plan_id=@subscriptionplanid,
		subscription_status=@subscription_status,contact_no=@contact_no,mobile_no=@mobile_no,updated_on=GETDATE(),updated_by=@created_by,Email=@email
		where pharmacy_id=@id
		UPDATE sa_superAdmin_sddress SET 
		address_line_1=@address1,address_line_2=@address2,country_id=@country_id,state_id=@state_id,
		city=@city,zipcode=@zipcode,updated_on=GETDATE(),updated_by=@created_by where pharmacy_id=@id
		set  @ph_id =@id ;
	END
	SELECT  top 1 * FROM pharmacy_list WHERE pharmacy_id = @ph_id
	SET NOCOUNT OFF;



END;

--select * from sa_pharmacy



--SELECT * FROM USERS






GO
/****** Object:  StoredProcedure [dbo].[SP_insert_update_sa_pharmacy_backup_19-06-2018]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO



CREATE PROCEDURE [dbo].[SP_insert_update_sa_pharmacy_backup_19-06-2018]
	(
	@id					int,
	@pharmacy_name		nvarchar(90),
	@pharmacy_ownerid	int,
	@pharmacy_logo		nvarchar(100),
	@registration_date	datetime,
	@subscriptionplanid int,
	@subscription_status nvarchar(50),
	@contact_no			 nvarchar(50),
	@mobile_no			 nvarchar(50),
	@created_by			 int,	
	@address1			 nvarchar(400),
	@address2			 nvarchar(400),
	@country_id			 int,
	@state_id			 int,
	@city_id			 int,
	@zipcode			 nvarchar(10),
	@email				 nvarchar(100),
	@user_id			 int
	/*@error				 varchar(2000) =null output*/
	)
 AS 
 BEGIN
 --declare @error				 varchar(2000)
 SET NOCOUNT ON;
	 IF(@id = 0)
	  BEGIN
		 --Begin tran 
		 begin try
		 --Select @error='Here in Try';
		
		  INSERT INTO pharmacy_list(pharmacy_name,pharmacy_owner_id,pharmacy_logo,registrationdate,subscription_plan_id
		  ,subscription_status,contact_no,mobile_no,created_by,created_on,is_deleted,Email,UserId) VALUES (@pharmacy_name,@pharmacy_ownerid,
		  @pharmacy_logo,@registration_date,@subscriptionplanid,@subscription_status,@contact_no,@mobile_no,@created_by,GETDATE(),0,@email,@user_id)
		
			DECLARE @ph_id int;
			set  @ph_id = (SELECT @@IDENTITY);

			INSERT into sa_superAdmin_sddress(pharmacy_id,address_line_1,address_line_2,country_id,state_id,
			city_id,zipcode,created_on,created_by,is_deleted) VALUES (@ph_id,@address1,@address2,@country_id,@state_id,@city_id,
			@zipcode,GETDATE(),@created_by,0)
			--rollback tran
			--select '1'
			--select @error
	 end try

		 begin catch
		 --Select @error=ERROR_MESSAGE()
		 --select '2'
		 end catch
		 
	   END 
	ELSE 
		BEGIN
		 select @pharmacy_ownerid
			UPDATE pharmacy_list SET 
			pharmacy_name=@pharmacy_name,pharmacy_owner_id=@pharmacy_ownerid,registrationdate=@registration_date,subscription_plan_id=@subscriptionplanid,
			subscription_status=@subscription_status,contact_no=@contact_no,mobile_no=@mobile_no,updated_on=GETDATE(),updated_by=@created_by,Email=@email,
			UserId=@user_id where pharmacy_id=@id

			UPDATE sa_superAdmin_sddress SET 
			address_line_1=@address1,address_line_2=@address2,country_id=@country_id,state_id=@state_id,
			city_id=@city_id,zipcode=@zipcode,updated_on=GETDATE(),updated_by=@created_by where pharmacy_id=@id
			--select '1'
			DECLARE @count INT;
			SELECT @count=ISNULL(COUNT(*),0) FROM users WHERE PhoneNumber=@contact_no
			IF(@count = 0)
			UPDATE users SET phoneNumber=@contact_no where Id=@user_id
	END

	

	SET NOCOUNT OFF;
END;

--select * from sa_pharmacy
--SELECT * FROM USERS




GO
/****** Object:  StoredProcedure [dbo].[SP_insert_update_sa_pharmacy1]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 27-02-2018
-- Description: SP to INSERT or UPDATE the record in sa_pharmacy table
-- =============================================

CREATE PROCEDURE [dbo].[SP_insert_update_sa_pharmacy1]
	(
	--@id					int,
	@pharmacy_name		nvarchar(90)
	
	)
 AS 
 
 --IF(@id = 0)
  BEGIN
  
	  INSERT INTO sa_pharmacy(pharmacy_name,created_on,is_deleted) VALUES (@pharmacy_name,GETDATE(),0)	
	  
	SELECT top 1 * FROM sa_pharmacy

	   
   END





GO
/****** Object:  StoredProcedure [dbo].[SP_insert_update_saInvoice]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 27-02-2018
-- Description: SP to ADD/UPDATE From SuperAdmin Invoice table
-- =============================================
CREATE PROCEDURE [dbo].[SP_insert_update_saInvoice]
		(
		@id int,
		@invoice_no nvarchar(150),
		@subscription_plan_id int,
		@pharmacy_id int,
		@status nvarchar(150),
		@subscription_amount nvarchar(150),
		@created_by int		
		)
 AS 
	IF(@id = 0)
	 BEGIN

		 INSERT INTO sa_superadmin_invoice(invoice_no,subscription_plan_id,pharmacy_id,i_status,subscription_amount,created_by,created_on,is_deleted)
		 VALUES (@invoice_no,@subscription_plan_id,@pharmacy_id,@status,@subscription_amount,@created_by,GETDATE(),0)

		 DECLARE @invoice_id int;
		set  @invoice_id = (SELECT @@IDENTITY);

		INSERT INTO sa_invoice_payment_details(superadmin_invoice_id,created_by,created_on,is_deleted) 
		VALUES (@invoice_id,@created_by,GETDATE(),0)

	 END

	 ELSE
	 BEGIN

	 	UPDATE sa_superadmin_invoice SET invoice_no=@invoice_no,subscription_plan_id=@subscription_plan_id,i_status=@status,
		subscription_amount=@subscription_amount,updated_by=@created_by,updated_on=GETDATE() where superadmin_invoice_id=@id

		UPDATE sa_invoice_payment_details SET Updated_by=@created_by,updated_on=GETDATE() WHERE superadmin_invoice_id=@id

	 END





GO
/****** Object:  StoredProcedure [dbo].[SP_insert_update_subscription]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 27-02-2018
-- Modified by: Sagar Sharma on 16-05-2018
-- Description: SP to ADD UPDATE From Subscription table
----EXEC SP_insert_update_subscription 15,'GoldPlan','2000','4','','Gold plan',1417,''
-- =============================================

	
  CREATE PROCEDURE [dbo].[SP_insert_update_subscription]
		(
		@id					INT,
		@Plan_name			NVARCHAR(90),
		@cost				DECIMAL(10,3),
		@months				INT,
		@features			NVARCHAR(2000),
		@desc				NVARCHAR(2000),		
		@created_by			INT,
		@status				NVARCHAR(50)
		)
 AS 
 BEGIN
  DECLARE @subscription_id INT=@id
   SET NOCOUNT ON;
	IF(@id = 0)
	 BEGIN
		 INSERT	into sa_subscription_plan(plan_name, cost, months, features, description, status, created_on, created_by, is_deleted)
		  VALUES (@plan_name, @cost, @months, @features, @desc, 'Active', GETDATE(), @created_by, 0)

		SET  @subscription_id = (SELECT @@IDENTITY); 
	END

	ELSE 
	 BEGIN
		UPDATE sa_subscription_plan SET
		 plan_name=			@Plan_name,
		 cost=				@cost,
		 months=			@months,
		 features=			@features,
		 description=		@desc,
		 status=			@status,
		 updated_on=		GETDATE(),
		 updated_by=		@created_by,
		 is_deleted=		0
		WHERE subscription_plan_id=@id
	END
	SELECT TOP 1 * From sa_subscription_plan where subscription_plan_id = @subscription_id;

	SET NOCOUNT OFF;
	END


	







GO
/****** Object:  StoredProcedure [dbo].[SP_inventory_overstock]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 16-04-2018
-- Description: SP to for oversupply with pagination
-- =============================================

CREATE PROC [dbo].[SP_inventory_overstock]
  @pharmacy_id			int,
  @PageSize			    int,
  @PageNumber			int,
  @SearchString		    nvarchar(100)= ''
  AS
   BEGIN

    CREATE TABLE #Temp_statusclassification
	(InventoryId		 INT,
	 PharmacyId			 INT,
	 WholesalerId		 INT, 
	 MedicineName		 NVARCHAR(500), 
	 QuantityOnHand		 INT,
	 OptimalQuantity	 INT, 
	 OverStocksSurplus	 DECIMAL(10,2),	
	 NDC			     BIGINT,
	 Count				 INT,
	 Price				 MONEY)

	INSERT INTO #Temp_statusclassification (InventoryId,PharmacyId,WholesalerId,MedicineName,QuantityOnHand,OptimalQuantity,NDC,Price)
	 SELECT
	     inventory_id					  AS InventoryId,
		 pharmacy_id					  AS PharmacyId,
		 wholesaler_id                    AS WholesalerId,
		 drug_name						  AS MedicineName,
		 pack_size						  AS QuantityOnHand,
		 dbo.FN_calculate_optimum_qty(ndc,@pharmacy_id)AS OptimalQuantity,		
		 ndc							  AS NDC,
		 price							  AS Price
		
	 FROM [dbo].[inventory] 
	 WHERE 	pharmacy_id = @pharmacy_id 

	 --select * from #Temp_statusclassification
	 UPDATE #Temp_statusclassification SET [OverStocksSurplus]=(CASE WHEN ((QuantityOnHand/100)>OptimalQuantity) THEN (QuantityOnHand/100)
															ELSE 0.00 END)  
   DECLARE @count int;
   SELECT @count=  IsNull(COUNT(*),0) FROM #Temp_statusclassification where  OverStocksSurplus > 0

	SELECT InventoryId,PharmacyId,WholesalerId,MedicineName,QuantityOnHand,OptimalQuantity,NDC,Price,OverStocksSurplus,@count AS Count
	FROM #Temp_statusclassification 
	WHERE 
		 pharmacyId=@pharmacy_id AND OverStocksSurplus > 0
		 AND (MedicineName LIKE '%'+ISNULL(@SearchString,MedicineName)+'%' OR
		 NDC LIKE '%'+ISNULL(@SearchString,NDC)+'%')
		 ORDER BY InventoryId 
		 OFFSET  @PageSize * (@PageNumber - 1)   ROWS
		 FETCH NEXT @PageSize ROWS ONLY	


		 DROP TABLE #Temp_statusclassification	
		 	END
			--EXEC [SP_inventory_overstock] 1417,10,1,''




GO
/****** Object:  StoredProcedure [dbo].[SP_Inventory_processor]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:     
-- Create date: 
-- Description: SP to Insert the inventory after parsing EDI and CSV file from wholesaler
-- Updated date: 04/09/2019
-- Updated SP to reset -ve inventory.
-- =============================================



CREATE PROC [dbo].[SP_Inventory_processor]  
	AS
   BEGIN
   BEGIN TRY
		INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','Processing EDI parsed data'); 

   /*Fetch data from wholesaler EDI Invoice*/

   DECLARE @INVOICE_STATUS  NVARCHAR(20)
   SET @INVOICE_STATUS  = 'NEW'
   
   DECLARE @INVENTORY_SOURCE_ID  INT
   SET @INVENTORY_SOURCE_ID  = 1


   /* 
   Temp table created for implementing join on edi inventory table to get pack size from edi_inventory table   
   */
    CREATE TABLE #temp_edi_inventory_rec(
		ndc BIGINT,
		pack_size DECIMAL(10,2),
		strength NVARCHAR(100)
	)

	INSERT INTO #temp_edi_inventory_rec (ndc)
		SELECT DISTINCT  ISNULL(TRY_PARSE(LIN_NDC AS BIGINT),0)  FROM edi_inventory
	
	UPDATE temp_inv_rec
		SET temp_inv_rec.pack_size = (CAST(ISNULL(E.[PO4_Pack_FDBSize],0.0) AS Decimal(10,2)) * CAST(ISNULL(E.[PO4_Pack_MetricSize],0.0) AS DECIMAL(10,2))),
		temp_inv_rec.strength = ISNULL(E.PID_Strength,'')
		--SET temp_inv_rec.pack_size = CAST(ISNULL(E.[PO4_Pack_FDBSize],0.0) AS Decimal(10,2))
	FROM #temp_edi_inventory_rec temp_inv_rec
	INNER JOIN edi_inventory E
		ON temp_inv_rec.NDC = TRY_PARSE(E.LIN_NDC AS BIGINT) 

   CREATE TABLE #pending_invoice(
			[invoice_id] INT,
			[status] NVARCHAR(20),
			pharmacy_id INT,
			batch_id	INT,
			WholesalerId INT,
			[invoice_date] DateTime		--------------> added on 23-05-2018 
   )
      
   CREATE TABLE #pending_invoice_line_items(
			invoice_lineitem_id INT,  /*Added new column*/			
			invoiced_quantity DECIMAL(10,2), 
			WholesalerId INT,
			ndc_upc	BIGINT,	 				
			unit_price MONEY,
			product_desc VARCHAR(500),
			pharmacy_id INT,
			batch_id	INT,
			invoice_date DATETIME,
			ndc_packsize  DECIMAL(10,2),			
			strength  NVARCHAR(100),
			received_quantity	DECIMAL(10,2) /*Added new column*/				
   )
   

   INSERT INTO #pending_invoice
	   SELECT  			
			inv.[invoice_id],
			inv.[status],
			inv.[pharmacy_id],
			inv.[edi_batch_details_id],
			inv.[WholesalerId],
			inv.[invoice_date] --------------> added on 23-05-2018 
		FROM [dbo].[invoice] inv	
		WHERE inv.status = @INVOICE_STATUS
			

   INSERT INTO #pending_invoice_line_items (invoiced_quantity, WholesalerId,ndc_upc,unit_price,product_desc,pharmacy_id, batch_id,invoice_date,ndc_packsize,strength,received_quantity,invoice_lineitem_id)
		SELECT
			 CONVERT(DECIMAL,invli.[invoiced_quantity]),
			pinv.WholesalerId,
			CONVERT(BIGINT, invli.[ndc_upc]),
			invli.[unit_price],
			invpd.[product_desc],
			pinv.[pharmacy_id],
			pinv.batch_id,
			pinv.invoice_date,
			--(CAST(ISNULL(edi_inv.[PO4_Pack_FDBSize],0.0) AS Decimal(10,2)) * CAST(ISNULL(edi_inv.[PO4_Pack_MetricSize],0.0) AS DECIMAL(10,2)))
			rec.pack_size,
			rec.strength,
			CONVERT(DECIMAL,invli.[invoiced_quantity]) * CONVERT(DECIMAL,rec.pack_size), /*Added new column*/	
			invoice_lineitem_id
		FROM [dbo].[invoice_line_items] invli
			INNER JOIN [dbo].[invoice_productDescription] invpd ON invpd.[invoice_items_id] = invli.[invoice_lineitem_id]
			INNER JOIN #pending_invoice pinv ON pinv.invoice_id = invli.[invoice_id]
			LEFT JOIN #temp_edi_inventory_rec rec
				ON invli.[ndc_upc] = rec.ndc 
					
	
	UPDATE temp_pili
		SET temp_pili.product_desc = fdb_prd.NONPROPRIETARYNAME 
	FROM #pending_invoice_line_items temp_pili 
	INNER JOIN  [dbo].[FDB_Package] fdb_pkg		
		 ON fdb_pkg.NDCINT = CAST(temp_pili.ndc_upc AS BIGINT)
	INNER JOIN [dbo].[FDB_Product] fdb_prd ON fdb_prd.PRODUCTID =  fdb_pkg.PRODUCTID

	-- end --

	/*PrashantW:Begin 10/04/2019 - Reset negative inventory*/
	--CREATE TABLE #temp_negative_inventory(
	CREATE TABLE #temp_pending_reorder(
		row_id				INT IDENTITY (1,1),			
		pending_reorder_id				INT,
		inventory_id					INT,
		pharmacy_id						INT, 	
		ndc								BIGINT,
		qty_reorder						DECIMAL(10,2)							
	)
	
	INSERT INTO #temp_pending_reorder
		SELECT inv_pen_ord.pending_reorder_id, inv_pen_ord.inventory_id, inv_pen_ord.pharmacy_id, inv_pen_ord.ndc, inv_pen_ord.qty_reorder
		FROM pending_reorder inv_pen_ord
		INNER JOIN #pending_invoice_line_items invli ON invli.ndc_upc = inv_pen_ord.ndc
		WHERE inv_pen_ord.qty_reorder > 0 
	
	
	DECLARE @count INT
    SELECT  @count= count(*) FROM #temp_pending_reorder	
	DECLARE @index INT =1
	DECLARE @ph_id INT, @inventory_id INT, @pending_reorder_id INT, @ndc BIGINT, @qty_reorder DECIMAL(10,3)
	DECLARE @invoice_lineitem_id INT, @received_quantity DECIMAL(10,3);
	print('p1')		
	WHILE(@index <= @count)
	BEGIN /*WHILE1*/
		print('p2')		
		
		SET @qty_reorder = 0
		
		SET @inventory_id = 0
		SET @ph_id = 0
		SET @ndc = 0		
		SET @pending_reorder_id = 0
				
		SELECT @ndc=ndc, @ph_id=pharmacy_id, @qty_reorder= qty_reorder, @inventory_id = inventory_id, @pending_reorder_id = pending_reorder_id  
		FROM #temp_pending_reorder WHERE row_id=@index;
						
			
		WHILE(@qty_reorder > 0) 
		BEGIN /*WHILE2*/
			print('p3')		
			DECLARE @received_quantity_reset DECIMAL(10,2)
			DECLARE @pending_quantity_reset DECIMAL(10,2)
			DECLARE @zero DECIMAL(10,3) = 0

			SET @received_quantity = 0
			SET @invoice_lineitem_id = 0

			print(@qty_reorder)
			
			SELECT  @received_quantity = ISNULL(invli.received_quantity,0), @invoice_lineitem_id = invli.invoice_lineitem_id 
			FROM #pending_invoice_line_items invli WHERE invli.ndc_upc = @ndc AND invli.pharmacy_id = @ph_id AND invli.received_quantity >0

			print(@received_quantity)
			IF (ISNULL(@received_quantity,0) > @zero)
			BEGIN
				IF (@received_quantity >= @qty_reorder)
				BEGIN
					SET @received_quantity_reset = (@received_quantity-@qty_reorder)
					SET @pending_quantity_reset =0

					INSERT INTO pending_reorder_log(pending_reorder_id, ndc, received_quantity,pending_quantity,received_quantity_reset, pending_quantity_reset,pharmacy_id, created_on) VALUES(
						@pending_reorder_id, @ndc, @received_quantity, @qty_reorder, @received_quantity_reset,@pending_quantity_reset,@ph_id,GETDATE())				

					INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','if1 Reset pending reorder inventory. inventory_id =' + CAST(ISNULL(@inventory_id,0) AS VARCHAR(20)) + ' ndc=' + CAST(@ndc AS VARCHAR(20)) + ' old pending reorder qty=' + CAST(@qty_reorder AS VARCHAR(20)) + ' received qty=' +  CAST(@received_quantity AS VARCHAR(20)) + ' pharmacy_id=' +  CAST(@ph_id AS VARCHAR(20)))
				
					SET @received_quantity = (@received_quantity-@qty_reorder)
					SET @qty_reorder = 0 /*close while loop WHILE2*/
					print('if1')												
				END
				ELSE
				BEGIN					
					SET @received_quantity_reset = 0
					SET @pending_quantity_reset = (@qty_reorder - @received_quantity)
								
					INSERT INTO pending_reorder_log(pending_reorder_id, ndc, received_quantity,pending_quantity,received_quantity_reset, pending_quantity_reset,pharmacy_id, created_on) VALUES(
						@pending_reorder_id, @ndc, @received_quantity, @qty_reorder, @received_quantity_reset,@pending_quantity_reset,@ph_id,GETDATE())

											
					INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','if2 Reset pending reorder inventory. inventory_id =' + CAST(ISNULL(@inventory_id,0) AS VARCHAR(20)) + ' ndc=' + CAST(@ndc AS VARCHAR(20)) + ' old -ve qty=' + CAST(@qty_reorder AS VARCHAR(20)) + ' received qty=' +  CAST(@received_quantity AS VARCHAR(20)) + ' pharmacy_id=' +  CAST(@ph_id AS VARCHAR(20)))
					
					SET @qty_reorder = (@qty_reorder - @received_quantity)
					SET @received_quantity = 0

					print('if2')															
				END
				
				UPDATE #pending_invoice_line_items SET received_quantity = @received_quantity WHERE invoice_lineitem_id = @invoice_lineitem_id
				UPDATE #temp_pending_reorder SET qty_reorder = @qty_reorder WHERE row_id = @index 				
			END						
			ELSE
			BEGIN
				print('if3')	
				SET @qty_reorder = 0 /*close while loop WHILE2*/
			END
		END /*WHILE2*/				
		SET @index=@index+1

	END /*WHILE1*/
	
	UPDATE pro
		SET pro.qty_reorder = tmp_pro.qty_reorder
	FROM [dbo].[pending_reorder] pro
		INNER JOIN #temp_pending_reorder tmp_pro ON tmp_pro.pending_reorder_id = pro.pending_reorder_id
	
		
	DROP TABLE #temp_pending_reorder
	/*PrashantW:End 10/04/2019 - Reset negative inventory*/

	INSERT INTO inventory (pack_size, wholesaler_id, ndc, price, drug_name,pharmacy_id,batch_id,inventory_source_id,created_on,is_deleted,NDC_Packsize,Strength) 
		SELECT 
			/*CONVERT(DECIMAL,invli.[invoiced_quantity]) * CONVERT(DECIMAL,invli.ndc_packsize),*/
			invli.received_quantity,
			invli.WholesalerId,
			CONVERT(BIGINT, invli.[ndc_upc]),
			(invli.[unit_price]/nullif(invli.ndc_packsize,0)),
			--invli.[unit_price],
			invli.[product_desc],		
			invli.[pharmacy_id],
			invli.batch_id,
			@INVENTORY_SOURCE_ID,
			/* with the invoice_date can be reverted in future ,comment on 23-05-2018
			GETDATE()
			*/
			invli.invoice_date,  
			0,
			invli.ndc_packsize,
			invli.strength

		/*FROM [dbo].[invoice_line_items] invli	
			INNER JOIN [dbo].[invoice_productDescription] invpd 
				ON invpd.[invoice_items_id] = invli.[invoice_lineitem_id]		
			INNER JOIN #pending_invoice pinv ON pinv.invoice_id = invli.[invoice_id] 
		*/
		FROM #pending_invoice_line_items invli			
		WHERE invli.received_quantity >0

	INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','Insert edi parsed data to inventory table.'); 
	
	UPDATE inv
		SET inv.status = 'PROCESSED'
	FROM [dbo].[invoice] inv
		INNER JOIN #pending_invoice pinv ON pinv.invoice_id = inv.invoice_id


	DROP TABLE #pending_invoice
	DROP TABLE #pending_invoice_line_items
	Drop Table 	#temp_edi_inventory_rec	 

	INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','change the status of parsed data to PROCESSED in invoice table.'); 
   
   /****************************************/
   
   CREATE TABLE #temp_edi_inventory(
		ndc BIGINT,
		pack_size DECIMAL(10,2),
		drug_name nvarchar(2000),
		strength NVARCHAR(100)
	)
	
	INSERT INTO #temp_edi_inventory (ndc)
		select distinct  ISNULL(TRY_PARSE(LIN_NDC AS BIGINT),0)  from edi_inventory
		
	UPDATE temp_inv
		SET temp_inv.pack_size = (CAST(ISNULL(E.[PO4_Pack_FDBSize],0.0) AS Decimal(10,2)) * CAST(ISNULL(E.[PO4_Pack_MetricSize],0.0) AS DECIMAL(10,2))),
		temp_inv.strength = ISNULL(E.PID_Strength,'')
		--SET temp_inv.pack_size = CAST(ISNULL(E.[PO4_Pack_FDBSize],0.0) AS Decimal(10,2)) 
	FROM #temp_edi_inventory temp_inv
		INNER JOIN edi_inventory E
			ON temp_inv.NDC = TRY_PARSE(E.LIN_NDC AS BIGINT)  

	  
	  UPDATE temp_invc
		SET temp_invc.drug_name =   fdb_prd.NONPROPRIETARYNAME
	  FROM #temp_edi_inventory temp_invc 
		LEFT JOIN  [dbo].[FDB_Package] fdb_pkg	ON fdb_pkg.NDCINT = CAST(temp_invc.NDC AS BIGINT)
		INNER JOIN [dbo].[FDB_Product] fdb_prd ON fdb_prd.PRODUCTID =  fdb_pkg.PRODUCTID



   /*Fetch data CSV Import*/
   -- Fetch data from CSV import table having status =1.
   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'CSV data processor','Processing CSV parsed data'); 

		  --DECLARE @INVENTORY_SOURCE_ID  INT

		 SET @INVENTORY_SOURCE_ID  = 2	

		INSERT INTO inventory (pack_size, wholesaler_id, generic_code, ndc, price, drug_name, pharmacy_id,batch_id,inventory_source_id,created_on,is_deleted,NDC_Packsize,Strength) 
			SELECT
			   wcsv.pack_size AS quantity,
			   wcsvBM.wholesaler_id,
			   wcsv.generic_code,
			   wcsv.ndc, 
			   wcsv.price AS price,
			   IsNULL(a.drug_name,wcsv.drug_name),   -- we are use this drug name from FDA DB 
			   --wcsv.drug_name,
			   wcsvBM.pharmacy_id,
			   wcsv.csvbatch_id,
			   @INVENTORY_SOURCE_ID AS source,
			   ISNULL(wcsv.purchasedate,GETDATE()),
			   0,
			   ISNULL(a.pack_size,0.0) As PACK_SIZE,
			   a.strength
		FROM wholesaler_csvimport_batch_master wcsvBM 			   
			   INNER JOIN  wholesaler_csvimport_batch_details wcsvBD
					ON wcsvBM.csvimport_batch_id = wcsvBD.csvimport_batch_id			   
			   INNER JOIN wholesaler_CSV_Import wcsv
					ON wcsv.csvbatch_id = wcsvBD.csvimport_batch_id
			   LEFT JOIN #temp_edi_inventory a
					ON wcsv.NDC = a.ndc 
		WHERE wcsv.status_id=1	AND ISNULL(wcsv.is_deleted,0) =0	

		DROP TABLE #temp_edi_inventory


		INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'CSV data processor','Insert CSV parsed data to inventory table.'); 		
		-- Update the status of currently imported data to processed.
		UPDATE wholesaler_CSV_Import SET status_id = 2 WHERE status_id=1

		INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'CSV data processor','change the status of parsed data to PROCESSED in wholesaler_csv_import table.');    

   /****************************************/      	
   END TRY   
   BEGIN CATCH
		INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'Error','ERROR_LINE: ' + CAST(ERROR_LINE() AS VARCHAR(20)) + ' ERROR_MESSAGE:  '  + ERROR_MESSAGE()); 		
   END CATCH
   
   BEGIN TRY
		/*RX30 Quantity substract */
		INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'RX30 data Processor','calling SP_RX30_Inventory_Processor for updating inventory table.'); 

		EXEC SP_RX30_Inventory_Processor
   END TRY
   BEGIN CATCH
		INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'Error','ERROR_LINE: ' + CAST(ERROR_LINE() AS VARCHAR(20)) + ' ERROR_MESSAGE:  '  + ERROR_MESSAGE()); 		
   END CATCH   
   
   BEGIN TRY
   /* SP to update the strength and ndc packsize in inventory table where strength and ndcpacksize are null.*/
   EXEC sp_update_strength_ndcpacksize    
   /****************************************/
    END TRY
	BEGIN CATCH
		INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'Error','ERROR_LINE: ' + CAST(ERROR_LINE() AS VARCHAR(20)) + ' ERROR_MESSAGE:  '  + ERROR_MESSAGE()); 		
	END CATCH   
  END

















GO
/****** Object:  StoredProcedure [dbo].[SP_Inventory_processor_backup_07062018]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:     
-- Create date: 
-- Description: SP to Insert the inventory after parsing EDI and CSV file from wholesaler
-- =============================================

CREATE PROC [dbo].[SP_Inventory_processor_backup_07062018]
  
	AS
   BEGIN
   
   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','Processing EDI parsed data'); 

   /*Fetch data from wholesaler EDI Invoice*/
   DECLARE @INVOICE_STATUS  NVARCHAR(20)
   SET @INVOICE_STATUS  = 'NEW'

   DECLARE @INVENTORY_SOURCE_ID  INT
   SET @INVENTORY_SOURCE_ID  = 1


   CREATE TABLE #pending_invoice(
			[invoice_id] INT,
			[status] NVARCHAR(20),
			pharmacy_id INT,
			batch_id	INT,
			WholesalerId INT,
			[invoice_date] DateTime		--------------> added on 23-05-2018 
   )
   
   INSERT INTO #pending_invoice
	   SELECT  			
			inv.[invoice_id],
			inv.[status],
			inv.[pharmacy_id],
			inv.[edi_batch_details_id],
			inv.[WholesalerId],
			inv.[invoice_date] --------------> added on 23-05-2018 
		FROM [dbo].[invoice] inv	
		WHERE inv.status = @INVOICE_STATUS
		
	-- end --
	INSERT INTO inventory (pack_size, wholesaler_id, ndc, price, drug_name,pharmacy_id,batch_id,inventory_source_id,created_on,is_deleted) 
   SELECT 
		CONVERT(DECIMAL,invli.[invoiced_quantity]),
		pinv.WholesalerId,
		CONVERT(BIGINT, invli.[ndc_upc]),
		invli.[unit_price],
		invpd.[product_desc],
		pinv.[pharmacy_id],
		pinv.batch_id,
		@INVENTORY_SOURCE_ID,
		/* with the invoice_date can be reverted in future ,comment on 23-05-2018
		GETDATE()
		*/
		pinv.invoice_date,  
		0
				
	FROM [dbo].[invoice_line_items] invli
		INNER JOIN [dbo].[invoice_productDescription] invpd
			ON invpd.[invoice_items_id] = invli.[invoice_lineitem_id]
		INNER JOIN #pending_invoice pinv ON pinv.invoice_id = invli.[invoice_id] 

	INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','Insert edi parsed data to inventory table.'); 
		
	UPDATE inv
		SET inv.status = 'PROCESSED'
	FROM [dbo].[invoice] inv
		INNER JOIN #pending_invoice pinv ON pinv.invoice_id = inv.invoice_id

	DROP TABLE #pending_invoice

	INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','change the status of parsed data to PROCESSED in invoice table.'); 
   /****************************************/

   /*Fetch data CSV Import*/
   -- Fetch data from CSV import table having status =1.
   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'CSV data processor','Processing CSV parsed data'); 
		  --DECLARE @INVENTORY_SOURCE_ID  INT
		  SET @INVENTORY_SOURCE_ID  = 2
	
		INSERT INTO inventory (pack_size, wholesaler_id, generic_code, ndc, price, drug_name, pharmacy_id,batch_id,inventory_source_id,created_on,is_deleted) 
		 SELECT
			   wcsv.pack_size AS quantity,
			   wcsvBM.wholesaler_id,
			   wcsv.generic_code,
			   wcsv.ndc,
			   wcsv.price     AS price,
			   wcsv.drug_name,
			   wcsvBM.pharmacy_id,
			   wcsv.csvbatch_id,
			   @INVENTORY_SOURCE_ID AS source,
			   GETDATE(),
			   0
			   FROM wholesaler_csvimport_batch_master wcsvBM 
			   
			   INNER JOIN  wholesaler_csvimport_batch_details wcsvBD
			   
			   ON wcsvBM.csvimport_batch_id = wcsvBD.csvimport_batch_id
			   
			   INNER JOIN wholesaler_CSV_Import wcsv
			   
			   ON wcsv.csvbatch_id = wcsvBD.csvimport_batch_id
			   
			   WHERE wcsv.status_id=1

		INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'CSV data processor','Insert CSV parsed data to inventory table.'); 
		
		-- Update the status of currently imported data to processed.
		UPDATE wholesaler_CSV_Import SET status_id = 2 WHERE status_id=1
		INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'CSV data processor','change the status of parsed data to PROCESSED in wholesaler_csv_import table.'); 
   
   /****************************************/

   /*RX30 Quantity substract */
   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'RX30 data Processor','calling SP_RX30_Inventory_Processor for updating inventory table.'); 
   EXEC SP_RX30_Inventory_Processor
   
   /****************************************/
   



  END








GO
/****** Object:  StoredProcedure [dbo].[SP_Inventory_processor_backup_11062018]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:     
-- Create date: 
-- Description: SP to Insert the inventory after parsing EDI and CSV file from wholesaler
-- =============================================

CREATE PROC [dbo].[SP_Inventory_processor_backup_11062018]
  
	AS
   BEGIN
   
   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','Processing EDI parsed data'); 

   /*Fetch data from wholesaler EDI Invoice*/
   DECLARE @INVOICE_STATUS  NVARCHAR(20)
   SET @INVOICE_STATUS  = 'NEW'

   DECLARE @INVENTORY_SOURCE_ID  INT
   SET @INVENTORY_SOURCE_ID  = 1


   CREATE TABLE #pending_invoice(
			[invoice_id] INT,
			[status] NVARCHAR(20),
			pharmacy_id INT,
			batch_id	INT,
			WholesalerId INT,
			[invoice_date] DateTime		--------------> added on 23-05-2018 
   )
   
   INSERT INTO #pending_invoice
	   SELECT  			
			inv.[invoice_id],
			inv.[status],
			inv.[pharmacy_id],
			inv.[edi_batch_details_id],
			inv.[WholesalerId],
			inv.[invoice_date] --------------> added on 23-05-2018 
		FROM [dbo].[invoice] inv	
		WHERE inv.status = @INVOICE_STATUS
		
	-- end --
	INSERT INTO inventory (pack_size, wholesaler_id, ndc, price, drug_name,pharmacy_id,batch_id,inventory_source_id,created_on,is_deleted) 
   SELECT 
		CONVERT(DECIMAL,invli.[invoiced_quantity]),
		pinv.WholesalerId,
		CONVERT(BIGINT, invli.[ndc_upc]),
		invli.[unit_price],
		invpd.[product_desc],
		/*fdb_prd.NONPROPRIETARYNAME AS product_desc,*/
		pinv.[pharmacy_id],
		pinv.batch_id,
		@INVENTORY_SOURCE_ID,
		/* with the invoice_date can be reverted in future ,comment on 23-05-2018
		GETDATE()
		*/
		pinv.invoice_date,  
		0
				
	FROM [dbo].[invoice_line_items] invli
		INNER JOIN [dbo].[invoice_productDescription] invpd
			ON invpd.[invoice_items_id] = invli.[invoice_lineitem_id]
		/*INNER JOIN [dbo].[FDB_Package] fdb_pkg ON fdb_pkg.NDCINT = CAST(invli.ndc_upc AS INT)
		INNER JOIN [dbo].[FDB_Product] fdb_prd ON fdb_prd.PRODUCTID =  fdb_pkg.PRODUCTID*/
		INNER JOIN #pending_invoice pinv ON pinv.invoice_id = invli.[invoice_id] 

	INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','Insert edi parsed data to inventory table.'); 
		
	UPDATE inv
		SET inv.status = 'PROCESSED'
	FROM [dbo].[invoice] inv
		INNER JOIN #pending_invoice pinv ON pinv.invoice_id = inv.invoice_id

	DROP TABLE #pending_invoice

	INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','change the status of parsed data to PROCESSED in invoice table.'); 
   /****************************************/

   /*Fetch data CSV Import*/
   -- Fetch data from CSV import table having status =1.
   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'CSV data processor','Processing CSV parsed data'); 
		  --DECLARE @INVENTORY_SOURCE_ID  INT
		  SET @INVENTORY_SOURCE_ID  = 2
	
		INSERT INTO inventory (pack_size, wholesaler_id, generic_code, ndc, price, drug_name, pharmacy_id,batch_id,inventory_source_id,created_on,is_deleted) 
		 SELECT
			   wcsv.pack_size AS quantity,
			   wcsvBM.wholesaler_id,
			   wcsv.generic_code,
			   wcsv.ndc,
			   wcsv.price     AS price,
			   wcsv.drug_name,
			   wcsvBM.pharmacy_id,
			   wcsv.csvbatch_id,
			   @INVENTORY_SOURCE_ID AS source,
			   GETDATE(),
			   0
			   FROM wholesaler_csvimport_batch_master wcsvBM 
			   
			   INNER JOIN  wholesaler_csvimport_batch_details wcsvBD
			   
			   ON wcsvBM.csvimport_batch_id = wcsvBD.csvimport_batch_id
			   
			   INNER JOIN wholesaler_CSV_Import wcsv
			   
			   ON wcsv.csvbatch_id = wcsvBD.csvimport_batch_id
			   
			   WHERE wcsv.status_id=1

		INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'CSV data processor','Insert CSV parsed data to inventory table.'); 
		
		-- Update the status of currently imported data to processed.
		UPDATE wholesaler_CSV_Import SET status_id = 2 WHERE status_id=1
		INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'CSV data processor','change the status of parsed data to PROCESSED in wholesaler_csv_import table.'); 
   
   /****************************************/

   /*RX30 Quantity substract */
   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'RX30 data Processor','calling SP_RX30_Inventory_Processor for updating inventory table.'); 
   EXEC SP_RX30_Inventory_Processor
   
   /****************************************/
   



  END








GO
/****** Object:  StoredProcedure [dbo].[SP_Inventory_processor_backup_13_06_2018]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:     
-- Create date: 
-- Description: SP to Insert the inventory after parsing EDI and CSV file from wholesaler
-- =============================================

Create PROC [dbo].[SP_Inventory_processor_backup_13_06_2018]
  
	AS
   BEGIN
   
   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','Processing EDI parsed data'); 

   /*Fetch data from wholesaler EDI Invoice*/
   DECLARE @INVOICE_STATUS  NVARCHAR(20)
   SET @INVOICE_STATUS  = 'NEW'

   DECLARE @INVENTORY_SOURCE_ID  INT
   SET @INVENTORY_SOURCE_ID  = 1


   CREATE TABLE #pending_invoice(
			[invoice_id] INT,
			[status] NVARCHAR(20),
			pharmacy_id INT,
			batch_id	INT,
			WholesalerId INT,
			[invoice_date] DateTime		--------------> added on 23-05-2018 
   )
   
   CREATE TABLE #pending_invoice_line_items(			
			invoiced_quantity DECIMAL(10,2), 
			WholesalerId INT,
			ndc_upc	BIGINT,	 				
			unit_price MONEY,
			product_desc VARCHAR(500),
			pharmacy_id INT,
			batch_id	INT,
			invoice_date DATETIME			
   )

   INSERT INTO #pending_invoice
	   SELECT  			
			inv.[invoice_id],
			inv.[status],
			inv.[pharmacy_id],
			inv.[edi_batch_details_id],
			inv.[WholesalerId],
			inv.[invoice_date] --------------> added on 23-05-2018 
		FROM [dbo].[invoice] inv	
		WHERE inv.status = @INVOICE_STATUS
		
	
   INSERT INTO #pending_invoice_line_items (invoiced_quantity, WholesalerId,ndc_upc,unit_price,product_desc,pharmacy_id, batch_id,invoice_date)
		SELECT
			 CONVERT(DECIMAL,invli.[invoiced_quantity]),
			pinv.WholesalerId,
			CONVERT(BIGINT, invli.[ndc_upc]),
			invli.[unit_price],
			invpd.[product_desc],
			pinv.[pharmacy_id],
			pinv.batch_id,
			pinv.invoice_date 
		FROM [dbo].[invoice_line_items] invli
		INNER JOIN [dbo].[invoice_productDescription] invpd ON invpd.[invoice_items_id] = invli.[invoice_lineitem_id]
		INNER JOIN #pending_invoice pinv ON pinv.invoice_id = invli.[invoice_id]

	UPDATE temp_pili
		SET temp_pili.product_desc = fdb_prd.NONPROPRIETARYNAME 
	FROM #pending_invoice_line_items temp_pili 
	INNER JOIN  [dbo].[FDB_Package] fdb_pkg		
		 ON fdb_pkg.NDCINT = CAST(temp_pili.ndc_upc AS BIGINT)
	INNER JOIN [dbo].[FDB_Product] fdb_prd ON fdb_prd.PRODUCTID =  fdb_pkg.PRODUCTID

	-- end --


	INSERT INTO inventory (pack_size, wholesaler_id, ndc, price, drug_name,pharmacy_id,batch_id,inventory_source_id,created_on,is_deleted) 
   SELECT 
		CONVERT(DECIMAL,invli.[invoiced_quantity]),
		invli.WholesalerId,
		CONVERT(BIGINT, invli.[ndc_upc]),
		invli.[unit_price],
		invli.[product_desc],		
		invli.[pharmacy_id],
		invli.batch_id,
		@INVENTORY_SOURCE_ID,
		/* with the invoice_date can be reverted in future ,comment on 23-05-2018
		GETDATE()
		*/
		invli.invoice_date,  
		0
				
	/*FROM [dbo].[invoice_line_items] invli	
		INNER JOIN [dbo].[invoice_productDescription] invpd 
			ON invpd.[invoice_items_id] = invli.[invoice_lineitem_id]		
		INNER JOIN #pending_invoice pinv ON pinv.invoice_id = invli.[invoice_id] 
	*/
	FROM #pending_invoice_line_items invli			
	

	INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','Insert edi parsed data to inventory table.'); 
		
	UPDATE inv
		SET inv.status = 'PROCESSED'
	FROM [dbo].[invoice] inv
		INNER JOIN #pending_invoice pinv ON pinv.invoice_id = inv.invoice_id

	DROP TABLE #pending_invoice
	DROP TABLE #pending_invoice_line_items
			 
	INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','change the status of parsed data to PROCESSED in invoice table.'); 
   /****************************************/

   /*Fetch data CSV Import*/
   -- Fetch data from CSV import table having status =1.
   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'CSV data processor','Processing CSV parsed data'); 
		  --DECLARE @INVENTORY_SOURCE_ID  INT
		  SET @INVENTORY_SOURCE_ID  = 2
	
		INSERT INTO inventory (pack_size, wholesaler_id, generic_code, ndc, price, drug_name, pharmacy_id,batch_id,inventory_source_id,created_on,is_deleted) 
		 SELECT
			   wcsv.pack_size AS quantity,
			   wcsvBM.wholesaler_id,
			   wcsv.generic_code,
			   wcsv.ndc,
			   wcsv.price     AS price,
			   wcsv.drug_name,
			   wcsvBM.pharmacy_id,
			   wcsv.csvbatch_id,
			   @INVENTORY_SOURCE_ID AS source,
			   GETDATE(),
			   0
			   FROM wholesaler_csvimport_batch_master wcsvBM 
			   
			   INNER JOIN  wholesaler_csvimport_batch_details wcsvBD
			   
			   ON wcsvBM.csvimport_batch_id = wcsvBD.csvimport_batch_id
			   
			   INNER JOIN wholesaler_CSV_Import wcsv
			   
			   ON wcsv.csvbatch_id = wcsvBD.csvimport_batch_id
			   
			   WHERE wcsv.status_id=1

		INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'CSV data processor','Insert CSV parsed data to inventory table.'); 
		
		-- Update the status of currently imported data to processed.
		UPDATE wholesaler_CSV_Import SET status_id = 2 WHERE status_id=1
		INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'CSV data processor','change the status of parsed data to PROCESSED in wholesaler_csv_import table.'); 
   
   /****************************************/

   /*RX30 Quantity substract */
   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'RX30 data Processor','calling SP_RX30_Inventory_Processor for updating inventory table.'); 
   EXEC SP_RX30_Inventory_Processor
   
   /****************************************/
   



  END








GO
/****** Object:  StoredProcedure [dbo].[SP_Inventory_processor_backup26-06-2018]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:     
-- Create date: 
-- Description: SP to Insert the inventory after parsing EDI and CSV file from wholesaler
-- =============================================

CREATE PROC [dbo].[SP_Inventory_processor_backup26-06-2018]
  
	AS
   BEGIN
   
   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','Processing EDI parsed data'); 

   /*Fetch data from wholesaler EDI Invoice*/
   DECLARE @INVOICE_STATUS  NVARCHAR(20)
   SET @INVOICE_STATUS  = 'NEW'

   DECLARE @INVENTORY_SOURCE_ID  INT
   SET @INVENTORY_SOURCE_ID  = 1


   CREATE TABLE #pending_invoice(
			[invoice_id] INT,
			[status] NVARCHAR(20),
			pharmacy_id INT,
			batch_id	INT,
			WholesalerId INT,
			[invoice_date] DateTime		--------------> added on 23-05-2018 
   )
   
   CREATE TABLE #pending_invoice_line_items(			
			invoiced_quantity DECIMAL(10,2), 
			WholesalerId INT,
			ndc_upc	BIGINT,	 				
			unit_price MONEY,
			product_desc VARCHAR(500),
			pharmacy_id INT,
			batch_id	INT,
			invoice_date DATETIME			
   )

   INSERT INTO #pending_invoice
	   SELECT  			
			inv.[invoice_id],
			inv.[status],
			inv.[pharmacy_id],
			inv.[edi_batch_details_id],
			inv.[WholesalerId],
			inv.[invoice_date] --------------> added on 23-05-2018 
		FROM [dbo].[invoice] inv	
		WHERE inv.status = @INVOICE_STATUS
		
	
   INSERT INTO #pending_invoice_line_items (invoiced_quantity, WholesalerId,ndc_upc,unit_price,product_desc,pharmacy_id, batch_id,invoice_date)
		SELECT
			 CONVERT(DECIMAL,invli.[invoiced_quantity]),
			pinv.WholesalerId,
			CONVERT(BIGINT, invli.[ndc_upc]),
			invli.[unit_price],
			invpd.[product_desc],
			pinv.[pharmacy_id],
			pinv.batch_id,
			pinv.invoice_date 
		FROM [dbo].[invoice_line_items] invli
		INNER JOIN [dbo].[invoice_productDescription] invpd ON invpd.[invoice_items_id] = invli.[invoice_lineitem_id]
		INNER JOIN #pending_invoice pinv ON pinv.invoice_id = invli.[invoice_id]

	UPDATE temp_pili
		SET temp_pili.product_desc = fdb_prd.NONPROPRIETARYNAME 
	FROM #pending_invoice_line_items temp_pili 
	INNER JOIN  [dbo].[FDB_Package] fdb_pkg		
		 ON fdb_pkg.NDCINT = CAST(temp_pili.ndc_upc AS BIGINT)
	INNER JOIN [dbo].[FDB_Product] fdb_prd ON fdb_prd.PRODUCTID =  fdb_pkg.PRODUCTID

	-- end --


	INSERT INTO inventory (pack_size, wholesaler_id, ndc, price, drug_name,pharmacy_id,batch_id,inventory_source_id,created_on,is_deleted) 
   SELECT 
		CONVERT(DECIMAL,invli.[invoiced_quantity]),
		invli.WholesalerId,
		CONVERT(BIGINT, invli.[ndc_upc]),
		invli.[unit_price],
		invli.[product_desc],		
		invli.[pharmacy_id],
		invli.batch_id,
		@INVENTORY_SOURCE_ID,
		/* with the invoice_date can be reverted in future ,comment on 23-05-2018
		GETDATE()
		*/
		invli.invoice_date,  
		0
				
	/*FROM [dbo].[invoice_line_items] invli	
		INNER JOIN [dbo].[invoice_productDescription] invpd 
			ON invpd.[invoice_items_id] = invli.[invoice_lineitem_id]		
		INNER JOIN #pending_invoice pinv ON pinv.invoice_id = invli.[invoice_id] 
	*/
	FROM #pending_invoice_line_items invli			
	

	INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','Insert edi parsed data to inventory table.'); 
		
	UPDATE inv
		SET inv.status = 'PROCESSED'
	FROM [dbo].[invoice] inv
		INNER JOIN #pending_invoice pinv ON pinv.invoice_id = inv.invoice_id

	DROP TABLE #pending_invoice
	DROP TABLE #pending_invoice_line_items
			 
	INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','change the status of parsed data to PROCESSED in invoice table.'); 
   /****************************************/

   /*Fetch data CSV Import*/
   -- Fetch data from CSV import table having status =1.
   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'CSV data processor','Processing CSV parsed data'); 
		  --DECLARE @INVENTORY_SOURCE_ID  INT
		  SET @INVENTORY_SOURCE_ID  = 2
	
		INSERT INTO inventory (pack_size, wholesaler_id, generic_code, ndc, price, drug_name, pharmacy_id,batch_id,inventory_source_id,created_on,is_deleted) 
		 SELECT
			   wcsv.pack_size AS quantity,
			   wcsvBM.wholesaler_id,
			   wcsv.generic_code,
			   wcsv.ndc,
			   wcsv.price     AS price,
			   wcsv.drug_name,
			   wcsvBM.pharmacy_id,
			   wcsv.csvbatch_id,
			   @INVENTORY_SOURCE_ID AS source,
			   GETDATE(),
			   0
			   FROM wholesaler_csvimport_batch_master wcsvBM 
			   
			   INNER JOIN  wholesaler_csvimport_batch_details wcsvBD
			   
			   ON wcsvBM.csvimport_batch_id = wcsvBD.csvimport_batch_id
			   
			   INNER JOIN wholesaler_CSV_Import wcsv
			   
			   ON wcsv.csvbatch_id = wcsvBD.csvimport_batch_id
			   
			   WHERE wcsv.status_id=1

		INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'CSV data processor','Insert CSV parsed data to inventory table.'); 
		
		-- Update the status of currently imported data to processed.
		UPDATE wholesaler_CSV_Import SET status_id = 2 WHERE status_id=1
		INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'CSV data processor','change the status of parsed data to PROCESSED in wholesaler_csv_import table.'); 
   
   /****************************************/

   /*RX30 Quantity substract */
   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'RX30 data Processor','calling SP_RX30_Inventory_Processor for updating inventory table.'); 
   EXEC SP_RX30_Inventory_Processor
   
   /****************************************/
   



  END








GO
/****** Object:  StoredProcedure [dbo].[SP_Inventory_processor_bk_04132019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================

-- Author:     

-- Create date: 

-- Description: SP to Insert the inventory after parsing EDI and CSV file from wholesaler

-- =============================================



CREATE PROC [dbo].[SP_Inventory_processor_bk_04132019]

  

	AS

   BEGIN

   

   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','Processing EDI parsed data'); 



   /*Fetch data from wholesaler EDI Invoice*/

   DECLARE @INVOICE_STATUS  NVARCHAR(20)

   SET @INVOICE_STATUS  = 'NEW'



   DECLARE @INVENTORY_SOURCE_ID  INT

   SET @INVENTORY_SOURCE_ID  = 1


   /* 
   Temp table created for implementing join on edi inventory table to get pack size from edi_inventory table   
   */
    CREATE TABLE #temp_edi_inventory_rec(
		ndc BIGINT,
		pack_size DECIMAL(10,2),
		strength NVARCHAR(100)
	)

	INSERT INTO #temp_edi_inventory_rec (ndc)
	select distinct  ISNULL(TRY_PARSE(LIN_NDC AS BIGINT),0)  from edi_inventory
	
	UPDATE temp_inv_rec

	SET temp_inv_rec.pack_size = (CAST(ISNULL(E.[PO4_Pack_FDBSize],0.0) AS Decimal(10,2)) * CAST(ISNULL(E.[PO4_Pack_MetricSize],0.0) AS DECIMAL(10,2))),
	 temp_inv_rec.strength = ISNULL(E.PID_Strength,'')
	--SET temp_inv_rec.pack_size = CAST(ISNULL(E.[PO4_Pack_FDBSize],0.0) AS Decimal(10,2))
	FROM #temp_edi_inventory_rec temp_inv_rec

	INNER JOIN edi_inventory E

	ON temp_inv_rec.NDC = TRY_PARSE(E.LIN_NDC AS BIGINT) 



   CREATE TABLE #pending_invoice(

			[invoice_id] INT,

			[status] NVARCHAR(20),

			pharmacy_id INT,

			batch_id	INT,

			WholesalerId INT,

			[invoice_date] DateTime		--------------> added on 23-05-2018 

   )

   

   CREATE TABLE #pending_invoice_line_items(			

			invoiced_quantity DECIMAL(10,2), 

			WholesalerId INT,

			ndc_upc	BIGINT,	 				

			unit_price MONEY,

			product_desc VARCHAR(500),

			pharmacy_id INT,

			batch_id	INT,

			invoice_date DATETIME,

			ndc_packsize  DECIMAL(10,2),
			
			strength  NVARCHAR(100)			

   )



   INSERT INTO #pending_invoice

	   SELECT  			

			inv.[invoice_id],

			inv.[status],

			inv.[pharmacy_id],

			inv.[edi_batch_details_id],

			inv.[WholesalerId],

			inv.[invoice_date] --------------> added on 23-05-2018 

		FROM [dbo].[invoice] inv	

		WHERE inv.status = @INVOICE_STATUS

		

	

   INSERT INTO #pending_invoice_line_items (invoiced_quantity, WholesalerId,ndc_upc,unit_price,product_desc,pharmacy_id, batch_id,invoice_date,ndc_packsize,strength)

		SELECT

			 CONVERT(DECIMAL,invli.[invoiced_quantity]),

			pinv.WholesalerId,

			CONVERT(BIGINT, invli.[ndc_upc]),

			invli.[unit_price],

			invpd.[product_desc],

			pinv.[pharmacy_id],

			pinv.batch_id,

			pinv.invoice_date,
			--(CAST(ISNULL(edi_inv.[PO4_Pack_FDBSize],0.0) AS Decimal(10,2)) * CAST(ISNULL(edi_inv.[PO4_Pack_MetricSize],0.0) AS DECIMAL(10,2)))
			rec.pack_size,
			rec.strength

		FROM [dbo].[invoice_line_items] invli

		INNER JOIN [dbo].[invoice_productDescription] invpd ON invpd.[invoice_items_id] = invli.[invoice_lineitem_id]

		INNER JOIN #pending_invoice pinv ON pinv.invoice_id = invli.[invoice_id]
		LEFT JOIN #temp_edi_inventory_rec rec
		ON invli.[ndc_upc] = rec.ndc 

	
	
	UPDATE temp_pili

		SET temp_pili.product_desc = fdb_prd.NONPROPRIETARYNAME 

	FROM #pending_invoice_line_items temp_pili 

	INNER JOIN  [dbo].[FDB_Package] fdb_pkg		

		 ON fdb_pkg.NDCINT = CAST(temp_pili.ndc_upc AS BIGINT)

	INNER JOIN [dbo].[FDB_Product] fdb_prd ON fdb_prd.PRODUCTID =  fdb_pkg.PRODUCTID



	-- end --





	INSERT INTO inventory (pack_size, wholesaler_id, ndc, price, drug_name,pharmacy_id,batch_id,inventory_source_id,created_on,is_deleted,NDC_Packsize,Strength) 

   SELECT 

		CONVERT(DECIMAL,invli.[invoiced_quantity]) * CONVERT(DECIMAL,invli.ndc_packsize),
		invli.WholesalerId,
		CONVERT(BIGINT, invli.[ndc_upc]),
		(invli.[unit_price]/nullif(invli.ndc_packsize,0)),
		--invli.[unit_price],
		invli.[product_desc],		

		invli.[pharmacy_id],

		invli.batch_id,

		@INVENTORY_SOURCE_ID,

		/* with the invoice_date can be reverted in future ,comment on 23-05-2018

		GETDATE()

		*/

		invli.invoice_date,  

		0,

		invli.ndc_packsize,
		invli.strength

				

	/*FROM [dbo].[invoice_line_items] invli	

		INNER JOIN [dbo].[invoice_productDescription] invpd 

			ON invpd.[invoice_items_id] = invli.[invoice_lineitem_id]		

		INNER JOIN #pending_invoice pinv ON pinv.invoice_id = invli.[invoice_id] 

	*/

	FROM #pending_invoice_line_items invli			

	



	INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','Insert edi parsed data to inventory table.'); 

		

	UPDATE inv

		SET inv.status = 'PROCESSED'

	FROM [dbo].[invoice] inv

		INNER JOIN #pending_invoice pinv ON pinv.invoice_id = inv.invoice_id



	DROP TABLE #pending_invoice

	DROP TABLE #pending_invoice_line_items

	Drop Table 	#temp_edi_inventory_rec	 

	INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','change the status of parsed data to PROCESSED in invoice table.'); 

   /****************************************/







   CREATE TABLE #temp_edi_inventory(

	ndc BIGINT,

	pack_size DECIMAL(10,2),

	drug_name nvarchar(2000),

	strength NVARCHAR(100)

	)



INSERT INTO #temp_edi_inventory (ndc)

	select distinct  ISNULL(TRY_PARSE(LIN_NDC AS BIGINT),0)  from edi_inventory



UPDATE temp_inv

SET temp_inv.pack_size = (CAST(ISNULL(E.[PO4_Pack_FDBSize],0.0) AS Decimal(10,2)) * CAST(ISNULL(E.[PO4_Pack_MetricSize],0.0) AS DECIMAL(10,2))),
temp_inv.strength = ISNULL(E.PID_Strength,'')
--SET temp_inv.pack_size = CAST(ISNULL(E.[PO4_Pack_FDBSize],0.0) AS Decimal(10,2)) 
FROM #temp_edi_inventory temp_inv

INNER JOIN edi_inventory E

ON temp_inv.NDC = TRY_PARSE(E.LIN_NDC AS BIGINT)  

	  

	  UPDATE temp_invc

	  set temp_invc.drug_name =   fdb_prd.NONPROPRIETARYNAME

	  FROM #temp_edi_inventory temp_invc 

	  LEFT JOIN  [dbo].[FDB_Package] fdb_pkg		

	  ON fdb_pkg.NDCINT = CAST(temp_invc.NDC AS BIGINT)

	  INNER JOIN [dbo].[FDB_Product] fdb_prd ON fdb_prd.PRODUCTID =  fdb_pkg.PRODUCTID



   /*Fetch data CSV Import*/

   -- Fetch data from CSV import table having status =1.

   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'CSV data processor','Processing CSV parsed data'); 

		  --DECLARE @INVENTORY_SOURCE_ID  INT

		 SET @INVENTORY_SOURCE_ID  = 2

	

		INSERT INTO inventory (pack_size, wholesaler_id, generic_code, ndc, price, drug_name, pharmacy_id,batch_id,inventory_source_id,created_on,is_deleted,NDC_Packsize,Strength) 

		 SELECT

			   wcsv.pack_size AS quantity,

			   wcsvBM.wholesaler_id,

			   wcsv.generic_code,

			   wcsv.ndc, 

			   wcsv.price AS price,

			   IsNULL(a.drug_name,wcsv.drug_name),   -- we are use this drug name from FDA DB 

			   --wcsv.drug_name,

			   wcsvBM.pharmacy_id,

			   wcsv.csvbatch_id,

			   @INVENTORY_SOURCE_ID AS source,

			   ISNULL(wcsv.purchasedate,GETDATE()),

			   0,

			   ISNULL(a.pack_size,0.0) As PACK_SIZE,

			   a.strength

			   FROM wholesaler_csvimport_batch_master wcsvBM 

			   

			   INNER JOIN  wholesaler_csvimport_batch_details wcsvBD

			   ON wcsvBM.csvimport_batch_id = wcsvBD.csvimport_batch_id

			   

			   INNER JOIN wholesaler_CSV_Import wcsv

			   ON wcsv.csvbatch_id = wcsvBD.csvimport_batch_id



			   LEFT JOIN #temp_edi_inventory a

			   ON wcsv.NDC = a.ndc 



			   WHERE wcsv.status_id=1

		

		drop table #temp_edi_inventory



		INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'CSV data processor','Insert CSV parsed data to inventory table.'); 

		

		-- Update the status of currently imported data to processed.

		UPDATE wholesaler_CSV_Import SET status_id = 2 WHERE status_id=1

		INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'CSV data processor','change the status of parsed data to PROCESSED in wholesaler_csv_import table.'); 

   

   /****************************************/



   /*RX30 Quantity substract */

   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'RX30 data Processor','calling SP_RX30_Inventory_Processor for updating inventory table.'); 

   EXEC SP_RX30_Inventory_Processor

   /* SP to update the strength and ndc packsize in inventory table where strength and ndcpacksize are null.*/
   EXEC sp_update_strength_ndcpacksize 

   

   /****************************************/

   







  END















GO
/****** Object:  StoredProcedure [dbo].[SP_Inventory_processor_bk_04172019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:     
-- Create date: 
-- Description: SP to Insert the inventory after parsing EDI and CSV file from wholesaler
-- Updated date: 04/09/2019
-- Updated SP to reset -ve inventory.
-- =============================================



CREATE PROC [dbo].[SP_Inventory_processor_bk_04172019]  
	AS
   BEGIN   
   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','Processing EDI parsed data'); 

   /*Fetch data from wholesaler EDI Invoice*/

   DECLARE @INVOICE_STATUS  NVARCHAR(20)
   SET @INVOICE_STATUS  = 'NEW'
   
   DECLARE @INVENTORY_SOURCE_ID  INT
   SET @INVENTORY_SOURCE_ID  = 1


   /* 
   Temp table created for implementing join on edi inventory table to get pack size from edi_inventory table   
   */
    CREATE TABLE #temp_edi_inventory_rec(
		ndc BIGINT,
		pack_size DECIMAL(10,2),
		strength NVARCHAR(100)
	)

	INSERT INTO #temp_edi_inventory_rec (ndc)
		SELECT DISTINCT  ISNULL(TRY_PARSE(LIN_NDC AS BIGINT),0)  FROM edi_inventory
	
	UPDATE temp_inv_rec
		SET temp_inv_rec.pack_size = (CAST(ISNULL(E.[PO4_Pack_FDBSize],0.0) AS Decimal(10,2)) * CAST(ISNULL(E.[PO4_Pack_MetricSize],0.0) AS DECIMAL(10,2))),
		temp_inv_rec.strength = ISNULL(E.PID_Strength,'')
		--SET temp_inv_rec.pack_size = CAST(ISNULL(E.[PO4_Pack_FDBSize],0.0) AS Decimal(10,2))
	FROM #temp_edi_inventory_rec temp_inv_rec
	INNER JOIN edi_inventory E
		ON temp_inv_rec.NDC = TRY_PARSE(E.LIN_NDC AS BIGINT) 

   CREATE TABLE #pending_invoice(
			[invoice_id] INT,
			[status] NVARCHAR(20),
			pharmacy_id INT,
			batch_id	INT,
			WholesalerId INT,
			[invoice_date] DateTime		--------------> added on 23-05-2018 
   )
      
   CREATE TABLE #pending_invoice_line_items(
			invoice_lineitem_id INT,  /*Added new column*/			
			invoiced_quantity DECIMAL(10,2), 
			WholesalerId INT,
			ndc_upc	BIGINT,	 				
			unit_price MONEY,
			product_desc VARCHAR(500),
			pharmacy_id INT,
			batch_id	INT,
			invoice_date DATETIME,
			ndc_packsize  DECIMAL(10,2),			
			strength  NVARCHAR(100),
			received_quantity	DECIMAL(10,2) /*Added new column*/				
   )
   

   INSERT INTO #pending_invoice
	   SELECT  			
			inv.[invoice_id],
			inv.[status],
			inv.[pharmacy_id],
			inv.[edi_batch_details_id],
			inv.[WholesalerId],
			inv.[invoice_date] --------------> added on 23-05-2018 
		FROM [dbo].[invoice] inv	
		WHERE inv.status = @INVOICE_STATUS
			

   INSERT INTO #pending_invoice_line_items (invoiced_quantity, WholesalerId,ndc_upc,unit_price,product_desc,pharmacy_id, batch_id,invoice_date,ndc_packsize,strength,received_quantity,invoice_lineitem_id)
		SELECT
			 CONVERT(DECIMAL,invli.[invoiced_quantity]),
			pinv.WholesalerId,
			CONVERT(BIGINT, invli.[ndc_upc]),
			invli.[unit_price],
			invpd.[product_desc],
			pinv.[pharmacy_id],
			pinv.batch_id,
			pinv.invoice_date,
			--(CAST(ISNULL(edi_inv.[PO4_Pack_FDBSize],0.0) AS Decimal(10,2)) * CAST(ISNULL(edi_inv.[PO4_Pack_MetricSize],0.0) AS DECIMAL(10,2)))
			rec.pack_size,
			rec.strength,
			CONVERT(DECIMAL,invli.[invoiced_quantity]) * CONVERT(DECIMAL,rec.pack_size), /*Added new column*/	
			invoice_lineitem_id
		FROM [dbo].[invoice_line_items] invli
			INNER JOIN [dbo].[invoice_productDescription] invpd ON invpd.[invoice_items_id] = invli.[invoice_lineitem_id]
			INNER JOIN #pending_invoice pinv ON pinv.invoice_id = invli.[invoice_id]
			LEFT JOIN #temp_edi_inventory_rec rec
				ON invli.[ndc_upc] = rec.ndc 
					
	
	UPDATE temp_pili
		SET temp_pili.product_desc = fdb_prd.NONPROPRIETARYNAME 
	FROM #pending_invoice_line_items temp_pili 
	INNER JOIN  [dbo].[FDB_Package] fdb_pkg		
		 ON fdb_pkg.NDCINT = CAST(temp_pili.ndc_upc AS BIGINT)
	INNER JOIN [dbo].[FDB_Product] fdb_prd ON fdb_prd.PRODUCTID =  fdb_pkg.PRODUCTID

	-- end --

	/*PrashantW:Begin 10/04/2019 - Reset negative inventory*/
	CREATE TABLE #temp_negative_inventory(
		row_id				INT IDENTITY (1,1),	
		inventory_id					INT,
		pharmacy_id						INT, 	
		ndc								BIGINT,
		pack_size						DECIMAL(10,2)			
	)
	
	INSERT INTO #temp_negative_inventory
		SELECT inv.inventory_id, inv.pharmacy_id, inv.ndc, abs(inv.pack_size)
		FROM inventory inv
		INNER JOIN #pending_invoice_line_items invli ON invli.ndc_upc = inv.ndc
		WHERE inv.pack_size < 0 AND inv.is_deleted = 0
	
	
	DECLARE @count INT
    SELECT  @count= count(*) FROM #temp_negative_inventory	
	DECLARE @index INT =1
	WHILE(@index <= @count)
	BEGIN /*WHILE1*/
		DECLARE @ph_id@ INT, @inventory_id INT,@ph_id INT, @ndc BIGINT, @qty_negative DECIMAL(10,3);
		DECLARE @invoice_lineitem_id INT, @received_quantity DECIMAL(10,3);				
		SELECT @ndc=ndc, @ph_id=pharmacy_id, @qty_negative= pack_size, @inventory_id = inventory_id  FROM #temp_negative_inventory WHERE row_id=@index;
		SELECT  @received_quantity = invli.received_quantity, @invoice_lineitem_id = invli.invoice_lineitem_id from #pending_invoice_line_items invli WHERE invli.ndc_upc = @ndc AND invli.pharmacy_id = @ph_id
		
		IF (@received_quantity >= @qty_negative)
		BEGIN
			print('if1')
			UPDATE #pending_invoice_line_items SET received_quantity = (received_quantity-@qty_negative) WHERE invoice_lineitem_id = @invoice_lineitem_id
			UPDATE inventory SET is_deleted = 1 WHERE inventory_id = @inventory_id
			INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','Reset -ve inventory. inventory_id =' + CAST(@inventory_id AS VARCHAR(20)) + ' ndc=' + CAST(@ndc AS VARCHAR(20)) + ' old -ve qty=' + CAST(@qty_negative AS VARCHAR(20))); 
		END
		ELSE			
		BEGIN
			print('if2')
			UPDATE #pending_invoice_line_items SET received_quantity = 0 WHERE invoice_lineitem_id = @invoice_lineitem_id
			UPDATE inventory SET pack_size = (@received_quantity-@qty_negative) WHERE inventory_id = @inventory_id
			INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','Reset -ve inventory. inventory_id =' + CAST(@inventory_id AS VARCHAR(20)) + ' ndc=' + CAST(@ndc AS VARCHAR(20)) + ' old -ve qty=' + CAST(@qty_negative AS VARCHAR(20))); 
		END
		SELECT @received_quantity = 0, @qty_negative = 0, @invoice_lineitem_id = 0, @inventory_id = 0
		SET @index=@index+1
	END /*WHILE1*/
		
	DROP TABLE #temp_negative_inventory
	/*PrashantW:End 10/04/2019 - Reset negative inventory*/

	INSERT INTO inventory (pack_size, wholesaler_id, ndc, price, drug_name,pharmacy_id,batch_id,inventory_source_id,created_on,is_deleted,NDC_Packsize,Strength) 
		SELECT 
			/*CONVERT(DECIMAL,invli.[invoiced_quantity]) * CONVERT(DECIMAL,invli.ndc_packsize),*/
			invli.received_quantity,
			invli.WholesalerId,
			CONVERT(BIGINT, invli.[ndc_upc]),
			(invli.[unit_price]/nullif(invli.ndc_packsize,0)),
			--invli.[unit_price],
			invli.[product_desc],		
			invli.[pharmacy_id],
			invli.batch_id,
			@INVENTORY_SOURCE_ID,
			/* with the invoice_date can be reverted in future ,comment on 23-05-2018
			GETDATE()
			*/
			invli.invoice_date,  
			0,
			invli.ndc_packsize,
			invli.strength

		/*FROM [dbo].[invoice_line_items] invli	
			INNER JOIN [dbo].[invoice_productDescription] invpd 
				ON invpd.[invoice_items_id] = invli.[invoice_lineitem_id]		
			INNER JOIN #pending_invoice pinv ON pinv.invoice_id = invli.[invoice_id] 
		*/
		FROM #pending_invoice_line_items invli			
		
	INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','Insert edi parsed data to inventory table.'); 
	
	UPDATE inv
		SET inv.status = 'PROCESSED'
	FROM [dbo].[invoice] inv
		INNER JOIN #pending_invoice pinv ON pinv.invoice_id = inv.invoice_id


	DROP TABLE #pending_invoice
	DROP TABLE #pending_invoice_line_items
	Drop Table 	#temp_edi_inventory_rec	 

	INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','change the status of parsed data to PROCESSED in invoice table.'); 
   
   /****************************************/
   
   CREATE TABLE #temp_edi_inventory(
		ndc BIGINT,
		pack_size DECIMAL(10,2),
		drug_name nvarchar(2000),
		strength NVARCHAR(100)
	)
	
	INSERT INTO #temp_edi_inventory (ndc)
		select distinct  ISNULL(TRY_PARSE(LIN_NDC AS BIGINT),0)  from edi_inventory
		
	UPDATE temp_inv
		SET temp_inv.pack_size = (CAST(ISNULL(E.[PO4_Pack_FDBSize],0.0) AS Decimal(10,2)) * CAST(ISNULL(E.[PO4_Pack_MetricSize],0.0) AS DECIMAL(10,2))),
		temp_inv.strength = ISNULL(E.PID_Strength,'')
		--SET temp_inv.pack_size = CAST(ISNULL(E.[PO4_Pack_FDBSize],0.0) AS Decimal(10,2)) 
	FROM #temp_edi_inventory temp_inv
		INNER JOIN edi_inventory E
			ON temp_inv.NDC = TRY_PARSE(E.LIN_NDC AS BIGINT)  

	  
	  UPDATE temp_invc
		SET temp_invc.drug_name =   fdb_prd.NONPROPRIETARYNAME
	  FROM #temp_edi_inventory temp_invc 
		LEFT JOIN  [dbo].[FDB_Package] fdb_pkg	ON fdb_pkg.NDCINT = CAST(temp_invc.NDC AS BIGINT)
		INNER JOIN [dbo].[FDB_Product] fdb_prd ON fdb_prd.PRODUCTID =  fdb_pkg.PRODUCTID



   /*Fetch data CSV Import*/
   -- Fetch data from CSV import table having status =1.
   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'CSV data processor','Processing CSV parsed data'); 

		  --DECLARE @INVENTORY_SOURCE_ID  INT

		 SET @INVENTORY_SOURCE_ID  = 2	

		INSERT INTO inventory (pack_size, wholesaler_id, generic_code, ndc, price, drug_name, pharmacy_id,batch_id,inventory_source_id,created_on,is_deleted,NDC_Packsize,Strength) 
			SELECT
			   wcsv.pack_size AS quantity,
			   wcsvBM.wholesaler_id,
			   wcsv.generic_code,
			   wcsv.ndc, 
			   wcsv.price AS price,
			   IsNULL(a.drug_name,wcsv.drug_name),   -- we are use this drug name from FDA DB 
			   --wcsv.drug_name,
			   wcsvBM.pharmacy_id,
			   wcsv.csvbatch_id,
			   @INVENTORY_SOURCE_ID AS source,
			   ISNULL(wcsv.purchasedate,GETDATE()),
			   0,
			   ISNULL(a.pack_size,0.0) As PACK_SIZE,
			   a.strength
		FROM wholesaler_csvimport_batch_master wcsvBM 			   
			   INNER JOIN  wholesaler_csvimport_batch_details wcsvBD
					ON wcsvBM.csvimport_batch_id = wcsvBD.csvimport_batch_id			   
			   INNER JOIN wholesaler_CSV_Import wcsv
					ON wcsv.csvbatch_id = wcsvBD.csvimport_batch_id
			   LEFT JOIN #temp_edi_inventory a
					ON wcsv.NDC = a.ndc 
		WHERE wcsv.status_id=1		

		DROP TABLE #temp_edi_inventory


		INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'CSV data processor','Insert CSV parsed data to inventory table.'); 		
		-- Update the status of currently imported data to processed.
		UPDATE wholesaler_CSV_Import SET status_id = 2 WHERE status_id=1

		INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'CSV data processor','change the status of parsed data to PROCESSED in wholesaler_csv_import table.');    

   /****************************************/
   
   /*RX30 Quantity substract */
   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'RX30 data Processor','calling SP_RX30_Inventory_Processor for updating inventory table.'); 

   EXEC SP_RX30_Inventory_Processor

   /* SP to update the strength and ndc packsize in inventory table where strength and ndcpacksize are null.*/
   EXEC sp_update_strength_ndcpacksize    
   /****************************************/   
  END















GO
/****** Object:  StoredProcedure [dbo].[SP_Inventory_processor_bk_04182019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:     
-- Create date: 
-- Description: SP to Insert the inventory after parsing EDI and CSV file from wholesaler
-- Updated date: 04/09/2019
-- Updated SP to reset -ve inventory.
-- =============================================



CREATE PROC [dbo].[SP_Inventory_processor_bk_04182019]  
	AS
   BEGIN
   BEGIN TRY
		INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','Processing EDI parsed data'); 

   /*Fetch data from wholesaler EDI Invoice*/

   DECLARE @INVOICE_STATUS  NVARCHAR(20)
   SET @INVOICE_STATUS  = 'NEW'
   
   DECLARE @INVENTORY_SOURCE_ID  INT
   SET @INVENTORY_SOURCE_ID  = 1


   /* 
   Temp table created for implementing join on edi inventory table to get pack size from edi_inventory table   
   */
    CREATE TABLE #temp_edi_inventory_rec(
		ndc BIGINT,
		pack_size DECIMAL(10,2),
		strength NVARCHAR(100)
	)

	INSERT INTO #temp_edi_inventory_rec (ndc)
		SELECT DISTINCT  ISNULL(TRY_PARSE(LIN_NDC AS BIGINT),0)  FROM edi_inventory
	
	UPDATE temp_inv_rec
		SET temp_inv_rec.pack_size = (CAST(ISNULL(E.[PO4_Pack_FDBSize],0.0) AS Decimal(10,2)) * CAST(ISNULL(E.[PO4_Pack_MetricSize],0.0) AS DECIMAL(10,2))),
		temp_inv_rec.strength = ISNULL(E.PID_Strength,'')
		--SET temp_inv_rec.pack_size = CAST(ISNULL(E.[PO4_Pack_FDBSize],0.0) AS Decimal(10,2))
	FROM #temp_edi_inventory_rec temp_inv_rec
	INNER JOIN edi_inventory E
		ON temp_inv_rec.NDC = TRY_PARSE(E.LIN_NDC AS BIGINT) 

   CREATE TABLE #pending_invoice(
			[invoice_id] INT,
			[status] NVARCHAR(20),
			pharmacy_id INT,
			batch_id	INT,
			WholesalerId INT,
			[invoice_date] DateTime		--------------> added on 23-05-2018 
   )
      
   CREATE TABLE #pending_invoice_line_items(
			invoice_lineitem_id INT,  /*Added new column*/			
			invoiced_quantity DECIMAL(10,2), 
			WholesalerId INT,
			ndc_upc	BIGINT,	 				
			unit_price MONEY,
			product_desc VARCHAR(500),
			pharmacy_id INT,
			batch_id	INT,
			invoice_date DATETIME,
			ndc_packsize  DECIMAL(10,2),			
			strength  NVARCHAR(100),
			received_quantity	DECIMAL(10,2) /*Added new column*/				
   )
   

   INSERT INTO #pending_invoice
	   SELECT  			
			inv.[invoice_id],
			inv.[status],
			inv.[pharmacy_id],
			inv.[edi_batch_details_id],
			inv.[WholesalerId],
			inv.[invoice_date] --------------> added on 23-05-2018 
		FROM [dbo].[invoice] inv	
		WHERE inv.status = @INVOICE_STATUS
			

   INSERT INTO #pending_invoice_line_items (invoiced_quantity, WholesalerId,ndc_upc,unit_price,product_desc,pharmacy_id, batch_id,invoice_date,ndc_packsize,strength,received_quantity,invoice_lineitem_id)
		SELECT
			 CONVERT(DECIMAL,invli.[invoiced_quantity]),
			pinv.WholesalerId,
			CONVERT(BIGINT, invli.[ndc_upc]),
			invli.[unit_price],
			invpd.[product_desc],
			pinv.[pharmacy_id],
			pinv.batch_id,
			pinv.invoice_date,
			--(CAST(ISNULL(edi_inv.[PO4_Pack_FDBSize],0.0) AS Decimal(10,2)) * CAST(ISNULL(edi_inv.[PO4_Pack_MetricSize],0.0) AS DECIMAL(10,2)))
			rec.pack_size,
			rec.strength,
			CONVERT(DECIMAL,invli.[invoiced_quantity]) * CONVERT(DECIMAL,rec.pack_size), /*Added new column*/	
			invoice_lineitem_id
		FROM [dbo].[invoice_line_items] invli
			INNER JOIN [dbo].[invoice_productDescription] invpd ON invpd.[invoice_items_id] = invli.[invoice_lineitem_id]
			INNER JOIN #pending_invoice pinv ON pinv.invoice_id = invli.[invoice_id]
			LEFT JOIN #temp_edi_inventory_rec rec
				ON invli.[ndc_upc] = rec.ndc 
					
	
	UPDATE temp_pili
		SET temp_pili.product_desc = fdb_prd.NONPROPRIETARYNAME 
	FROM #pending_invoice_line_items temp_pili 
	INNER JOIN  [dbo].[FDB_Package] fdb_pkg		
		 ON fdb_pkg.NDCINT = CAST(temp_pili.ndc_upc AS BIGINT)
	INNER JOIN [dbo].[FDB_Product] fdb_prd ON fdb_prd.PRODUCTID =  fdb_pkg.PRODUCTID

	-- end --

	/*PrashantW:Begin 10/04/2019 - Reset negative inventory*/
	CREATE TABLE #temp_negative_inventory(
		row_id				INT IDENTITY (1,1),	
		inventory_id					INT,
		pharmacy_id						INT, 	
		ndc								BIGINT,
		pack_size						DECIMAL(10,2)			
	)
	
	INSERT INTO #temp_negative_inventory
		SELECT inv.inventory_id, inv.pharmacy_id, inv.ndc, abs(inv.pack_size)
		FROM inventory inv
		INNER JOIN #pending_invoice_line_items invli ON invli.ndc_upc = inv.ndc
		WHERE inv.pack_size < 0 AND inv.is_deleted = 0
	
	
	DECLARE @count INT
    SELECT  @count= count(*) FROM #temp_negative_inventory	
	DECLARE @index INT =1
	WHILE(@index <= @count)
	BEGIN /*WHILE1*/
		DECLARE @ph_id INT, @inventory_id INT, @ndc BIGINT, @qty_negative DECIMAL(10,3);
		DECLARE @invoice_lineitem_id INT, @received_quantity DECIMAL(10,3);		
				
		SELECT @ndc=ndc, @ph_id=pharmacy_id, @qty_negative= pack_size, @inventory_id = inventory_id  FROM #temp_negative_inventory WHERE row_id=@index;
		SELECT  @received_quantity = invli.received_quantity, @invoice_lineitem_id = invli.invoice_lineitem_id from #pending_invoice_line_items invli WHERE invli.ndc_upc = @ndc AND invli.pharmacy_id = @ph_id
		
		IF (@received_quantity >= @qty_negative)
		BEGIN
			print('if1')
			UPDATE #pending_invoice_line_items SET received_quantity = (received_quantity-@qty_negative) WHERE invoice_lineitem_id = @invoice_lineitem_id
			UPDATE inventory SET is_deleted = 1 WHERE inventory_id = @inventory_id
			INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','Reset -ve inventory. inventory_id =' + CAST(@inventory_id AS VARCHAR(20)) + ' ndc=' + CAST(@ndc AS VARCHAR(20)) + ' old -ve qty=' + CAST(@qty_negative AS VARCHAR(20))); 
		END
		ELSE			
		BEGIN
			print('if2')
			UPDATE #pending_invoice_line_items SET received_quantity = 0 WHERE invoice_lineitem_id = @invoice_lineitem_id
			UPDATE inventory SET pack_size = (@received_quantity-@qty_negative) WHERE inventory_id = @inventory_id
			INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','Reset -ve inventory. inventory_id =' + CAST(@inventory_id AS VARCHAR(20)) + ' ndc=' + CAST(@ndc AS VARCHAR(20)) + ' old -ve qty=' + CAST(@qty_negative AS VARCHAR(20))); 
		END
		SELECT @received_quantity = 0, @qty_negative = 0, @invoice_lineitem_id = 0, @inventory_id = 0,@ph_id = 0, @ndc = 0
		SET @index=@index+1
	END /*WHILE1*/
		
	DROP TABLE #temp_negative_inventory
	/*PrashantW:End 10/04/2019 - Reset negative inventory*/

	INSERT INTO inventory (pack_size, wholesaler_id, ndc, price, drug_name,pharmacy_id,batch_id,inventory_source_id,created_on,is_deleted,NDC_Packsize,Strength) 
		SELECT 
			/*CONVERT(DECIMAL,invli.[invoiced_quantity]) * CONVERT(DECIMAL,invli.ndc_packsize),*/
			invli.received_quantity,
			invli.WholesalerId,
			CONVERT(BIGINT, invli.[ndc_upc]),
			(invli.[unit_price]/nullif(invli.ndc_packsize,0)),
			--invli.[unit_price],
			invli.[product_desc],		
			invli.[pharmacy_id],
			invli.batch_id,
			@INVENTORY_SOURCE_ID,
			/* with the invoice_date can be reverted in future ,comment on 23-05-2018
			GETDATE()
			*/
			invli.invoice_date,  
			0,
			invli.ndc_packsize,
			invli.strength

		/*FROM [dbo].[invoice_line_items] invli	
			INNER JOIN [dbo].[invoice_productDescription] invpd 
				ON invpd.[invoice_items_id] = invli.[invoice_lineitem_id]		
			INNER JOIN #pending_invoice pinv ON pinv.invoice_id = invli.[invoice_id] 
		*/
		FROM #pending_invoice_line_items invli			
		
	INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','Insert edi parsed data to inventory table.'); 
	
	UPDATE inv
		SET inv.status = 'PROCESSED'
	FROM [dbo].[invoice] inv
		INNER JOIN #pending_invoice pinv ON pinv.invoice_id = inv.invoice_id


	DROP TABLE #pending_invoice
	DROP TABLE #pending_invoice_line_items
	Drop Table 	#temp_edi_inventory_rec	 

	INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'edi data processor','change the status of parsed data to PROCESSED in invoice table.'); 
   
   /****************************************/
   
   CREATE TABLE #temp_edi_inventory(
		ndc BIGINT,
		pack_size DECIMAL(10,2),
		drug_name nvarchar(2000),
		strength NVARCHAR(100)
	)
	
	INSERT INTO #temp_edi_inventory (ndc)
		select distinct  ISNULL(TRY_PARSE(LIN_NDC AS BIGINT),0)  from edi_inventory
		
	UPDATE temp_inv
		SET temp_inv.pack_size = (CAST(ISNULL(E.[PO4_Pack_FDBSize],0.0) AS Decimal(10,2)) * CAST(ISNULL(E.[PO4_Pack_MetricSize],0.0) AS DECIMAL(10,2))),
		temp_inv.strength = ISNULL(E.PID_Strength,'')
		--SET temp_inv.pack_size = CAST(ISNULL(E.[PO4_Pack_FDBSize],0.0) AS Decimal(10,2)) 
	FROM #temp_edi_inventory temp_inv
		INNER JOIN edi_inventory E
			ON temp_inv.NDC = TRY_PARSE(E.LIN_NDC AS BIGINT)  

	  
	  UPDATE temp_invc
		SET temp_invc.drug_name =   fdb_prd.NONPROPRIETARYNAME
	  FROM #temp_edi_inventory temp_invc 
		LEFT JOIN  [dbo].[FDB_Package] fdb_pkg	ON fdb_pkg.NDCINT = CAST(temp_invc.NDC AS BIGINT)
		INNER JOIN [dbo].[FDB_Product] fdb_prd ON fdb_prd.PRODUCTID =  fdb_pkg.PRODUCTID



   /*Fetch data CSV Import*/
   -- Fetch data from CSV import table having status =1.
   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'CSV data processor','Processing CSV parsed data'); 

		  --DECLARE @INVENTORY_SOURCE_ID  INT

		 SET @INVENTORY_SOURCE_ID  = 2	

		INSERT INTO inventory (pack_size, wholesaler_id, generic_code, ndc, price, drug_name, pharmacy_id,batch_id,inventory_source_id,created_on,is_deleted,NDC_Packsize,Strength) 
			SELECT
			   wcsv.pack_size AS quantity,
			   wcsvBM.wholesaler_id,
			   wcsv.generic_code,
			   wcsv.ndc, 
			   wcsv.price AS price,
			   IsNULL(a.drug_name,wcsv.drug_name),   -- we are use this drug name from FDA DB 
			   --wcsv.drug_name,
			   wcsvBM.pharmacy_id,
			   wcsv.csvbatch_id,
			   @INVENTORY_SOURCE_ID AS source,
			   ISNULL(wcsv.purchasedate,GETDATE()),
			   0,
			   ISNULL(a.pack_size,0.0) As PACK_SIZE,
			   a.strength
		FROM wholesaler_csvimport_batch_master wcsvBM 			   
			   INNER JOIN  wholesaler_csvimport_batch_details wcsvBD
					ON wcsvBM.csvimport_batch_id = wcsvBD.csvimport_batch_id			   
			   INNER JOIN wholesaler_CSV_Import wcsv
					ON wcsv.csvbatch_id = wcsvBD.csvimport_batch_id
			   LEFT JOIN #temp_edi_inventory a
					ON wcsv.NDC = a.ndc 
		WHERE wcsv.status_id=1		

		DROP TABLE #temp_edi_inventory


		INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'CSV data processor','Insert CSV parsed data to inventory table.'); 		
		-- Update the status of currently imported data to processed.
		UPDATE wholesaler_CSV_Import SET status_id = 2 WHERE status_id=1

		INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'CSV data processor','change the status of parsed data to PROCESSED in wholesaler_csv_import table.');    

   /****************************************/      	
   END TRY   
   BEGIN CATCH
		INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'Error','ERROR_LINE: ' + CAST(ERROR_LINE() AS VARCHAR(20)) + ' ERROR_MESSAGE:  '  + ERROR_MESSAGE()); 		
   END CATCH

   /*RX30 Quantity substract */
   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_Inventory_processor', GETDATE(),'RX30 data Processor','calling SP_RX30_Inventory_Processor for updating inventory table.'); 

   EXEC SP_RX30_Inventory_Processor

   /* SP to update the strength and ndc packsize in inventory table where strength and ndcpacksize are null.*/
   EXEC sp_update_strength_ndcpacksize    
   /****************************************/   
  END
















GO
/****** Object:  StoredProcedure [dbo].[SP_inventoryList]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================

-- Author:      Priyanka Chandak
-- Create date: 06-04-2018
-- Description: SP to show inventory list with pagination and serarching
-- Updated : Prashant Wanjari
-- Updated Date : 04/04/2019
-- Description : Alex saying sum of price is showing high.
	
-- exec SP_inventoryList1 1417,100,1,'test','1'

-- exec SP_inventoryList 12,50,1,''

-- =============================================



 CREATE PROC [dbo].[SP_inventoryList]

  @pharmacy_id  int,

  @PageSize		int,

  @PageNumber    int,

  @SearchString  nvarchar(100)=null,

  @strength      nvarchar(100)=null



	AS

   BEGIN

   DECLARE @count int;



--	select * from inventory where ndc = 116200116 and is_deleted = 0



CREATE TABLE #TEMP_INVENTORY(

	pharmacy_id		INT,

	drug_name		NVARCHAR(2000),

	ndc				BIGINT,

	Total_PkSize	DECIMAL(10,2),

	Total_UPrice	DECIMAL(18,2),

	strength		NVARCHAR(1000),

	form_code		NVARCHAR(1000),

	ndc_packsize	NVARCHAR(1000),

	pack_code		NVARCHAR(1000),

)

-- SELECT @strength



	INSERT INTO #TEMP_INVENTORY(pharmacy_id,drug_name,ndc,Total_PkSize,Total_UPrice,strength,form_code,ndc_packsize,pack_code)

	SELECT	

		 pharmacy_id       AS pharmacy_id,				  

		 drug_name		   AS drug_name,						  

		 ndc			   AS ndc,		

		-- pack_size       AS 	 Total_PkSize,				  

		SUM(pack_size)     AS Total_PkSize,					  

		 0.0		       AS Total_UPrice,

		 ''				AS strength,

		 ''			AS form_code,

		 ''			AS ndc_packsize,

		 ''			AS pack_code

		 FROM [dbo].[inventory] 

		 WHERE pharmacy_id = @pharmacy_id

		 AND  is_deleted = 0

		 AND pack_size > 0 

		 AND 

		 ((IsNull(@SearchString,'')='' and IsNull(@strength,'')='' and  1=1)

		 or (IsNull(@strength,'')<>'' and IsNull(@SearchString,'')='' and [Strength] LIKE '%' + @strength+'%' ) 

		or (IsNull(@SearchString,'')<>'' and IsNull(@strength,'')='' and (drug_name LIKE '%'+ISNULL(@SearchString,drug_name)+'%' OR

			(ndc LIKE '%'+ISNULL(@SearchString,ndc)+'%'))) 

		or(IsNull(@SearchString,'')<>'' and IsNull(@strength,'')<>''and (drug_name LIKE '%'+ISNULL(@SearchString,drug_name)+'%' OR

			(ndc LIKE '%'+ISNULL(@SearchString,ndc)+'%')) and [Strength] LIKE '%' + @strength+'%')	 

				)		

	  GROUP BY pharmacy_id,ndc, drug_name 



	 		

		 -- update the total price  and Pack Size from a NDC from inventory table

		UPDATE  tempinv SET    
				tempinv.Total_UPrice = tempinv.Total_PkSize * ISNULL(inv.price,0),
				tempinv.ndc_packsize = inv.NDC_Packsize
				--tempinv.strength  = inv.Strength

		FROM #TEMP_INVENTORY tempinv
		INNER JOIN inventory inv ON tempinv.ndc = inv.ndc
		/*Begin: Prashant W: 04-04-2019: Where condition added*/
		WHERE inv.pharmacy_id = @pharmacy_id
		AND  inv.is_deleted = 0
		AND inv.pack_size > 0 
		/*End: Prashant W: 04-04-2019: Where condition added*/

		-- Update the Form code of drug and Strength from edi_inventory table

		 UPDATE  tempinv1 SET    

					tempinv1.form_code = edi_inv.PID_Dosage_Form_Code,

					tempinv1.strength  = edi_inv.PID_Strength,

					tempinv1.pack_code  = edi_inv.PO4_Pack_code

				FROM #TEMP_INVENTORY tempinv1

				INNER JOIN edi_inventory edi_inv ON 

				---tempinv1.ndc = CONVERT(BIGINT, ISNULL(edi_inv.LIN_NDC,0))

				edi_inv.LIN_NDC	 = right('00000000000'+cast(tempinv1.ndc as varchar(11)),11)
				/*Prashant W: 04-04-2019: Where condition added*/
				WHERE edi_inv.pharmacy_id = @pharmacy_id

		 -- COUNT RECORD

		 SELECT @count= COUNT(*) FROM #TEMP_INVENTORY 



		 -- SELECT RECORD FROM TEMP TABLE

		 SELECT

		 pharmacy_id					  AS PharmacyId,

		 drug_name						  AS DrugName,

		 ndc							  AS NDC,

		 Total_PkSize					  AS PackSize,

		 Total_UPrice					  AS Price,

		 strength						  AS Strength,

		 form_code						  AS FormCode,

		 ndc_packsize					  AS NdcPacksize,

		 pack_code						  AS Packcode,		

		 @count                           As Count

		 FROM #TEMP_INVENTORY

		  ORDER BY Total_UPrice desc

		 OFFSET  @PageSize * (@PageNumber - 1)   ROWS

         FETCH NEXT @PageSize ROWS ONLY	



		 -- drop temporary table

		 DROP TABLE #TEMP_INVENTORY

  END





  --go



  --exec SP_inventoryList1 1417,10,1,'','1'

  --go





GO
/****** Object:  StoredProcedure [dbo].[SP_inventoryList_backup_9july2018]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 06-04-2018
-- Description: SP to show inventory list with pagination and serarching
-- exec SP_inventoryList 1417,1000,1,'test'
-- =============================================

create PROC [dbo].[SP_inventoryList_backup_9july2018]
  @pharmacy_id  int,
  @PageSize		int,
  @PageNumber    int,
  @SearchString  nvarchar(100)=null

	AS
   BEGIN
   DECLARE @count int;
    
	--======================================================
	-- Modified by ankit joshi on 12-05-2018
  	--======================================================

--	select * from inventory where ndc = 116200116 and is_deleted = 0

CREATE TABLE #TEMP_INVENTORY(
	pharmacy_id		INT,
	drug_name		NVARCHAR(2000),
	ndc				BIGINT,
	Total_PkSize	DECIMAL(10,2),
	Total_UPrice	DECIMAL(10,2),
	strength		NVARCHAR(1000),
	form_code		NVARCHAR(1000),
	ndc_packsize	NVARCHAR(1000),
	pack_code		NVARCHAR(1000),
)


	INSERT INTO #TEMP_INVENTORY(pharmacy_id,drug_name,ndc,Total_PkSize,Total_UPrice,strength,form_code,ndc_packsize,pack_code)
	SELECT	
		 pharmacy_id,				  
		 drug_name,						  
		 ndc,							  
		 SUM(pack_size) as Total_PkSize,					  
		 0.0,
		 '0',
		 '0',
		 '0',
		 '0'
		 FROM [dbo].[inventory] 
		 WHERE 	pharmacy_id = @pharmacy_id --@pharmacy_id 
		 AND  is_deleted = 0
		 AND pack_size > 0 
		 AND  (drug_name LIKE '%'+ISNULL(@SearchString,drug_name)+'%' OR ndc LIKE '%'+ISNULL(@SearchString,ndc)+'%')
		 GROUP BY pharmacy_id,ndc, drug_name


		 -- update the total price  and Pack Size from a NDC from inventory table
		 UPDATE  tempinv SET    
				tempinv.Total_UPrice = tempinv.Total_PkSize * inv.price,
				tempinv.ndc_packsize = inv.NDC_Packsize
				FROM #TEMP_INVENTORY tempinv
				INNER JOIN inventory inv ON tempinv.ndc = inv.ndc

		-- Update the Form code of drug and Strength from edi_inventory table
		 UPDATE  tempinv1 SET    
					tempinv1.form_code = edi_inv.PID_Dosage_Form_Code,
					tempinv1.strength  = edi_inv.PID_Strength,
					tempinv1.pack_code  = edi_inv.PO4_Pack_code
				FROM #TEMP_INVENTORY tempinv1
				INNER JOIN edi_inventory edi_inv ON 
				---tempinv1.ndc = CONVERT(BIGINT, ISNULL(edi_inv.LIN_NDC,0))
				edi_inv.LIN_NDC	 = right('00000000000'+cast(tempinv1.ndc as varchar(11)),11)

		 -- COUNT RECORD
		 SELECT @count= COUNT(*) FROM #TEMP_INVENTORY 

		 -- SELECT RECORD FROM TEMP TABLE
		 SELECT
		 pharmacy_id					  AS PharmacyId,
		 drug_name						  AS DrugName,
		 ndc							  AS NDC,
		 Total_PkSize					  AS PackSize,
		 Total_UPrice					  AS Price,
		 strength						  AS Strength,
		 form_code						  AS FormCode,
		 ndc_packsize					  AS NdcPacksize,
		 pack_code						  AS Packcode,		
		 @count                           As Count
		 FROM #TEMP_INVENTORY
		  ORDER BY Total_UPrice desc
		 OFFSET  @PageSize * (@PageNumber - 1)   ROWS
         FETCH NEXT @PageSize ROWS ONLY	

		 -- drop temporary table
		 DROP TABLE #TEMP_INVENTORY
  END




GO
/****** Object:  StoredProcedure [dbo].[SP_inventoryList_backup-28-06-2018]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO




-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 06-04-2018
-- Description: SP to show inventory list with pagination and serarching
-- =============================================

CREATE PROC [dbo].[SP_inventoryList_backup-28-06-2018]
  @pharmacy_id  int,
  @PageSize		int,
  @PageNumber    int,
  @SearchString  nvarchar(100)=null

	AS
   BEGIN
   DECLARE @count int;
    
	--======================================================
	-- Modified by ankit joshi on 12-05-2018
  	--======================================================

--	select * from inventory where ndc = 116200116 and is_deleted = 0

CREATE TABLE #TEMP_INVENTORY(
	pharmacy_id   int,
	drug_name	  Nvarchar(2000),
	ndc		      BIGINT,
	Total_PkSize  DECIMAL(10,2),
	Total_UPrice  DECIMAL(10,2)
)


	INSERT INTO #TEMP_INVENTORY(pharmacy_id,drug_name,ndc,Total_PkSize,Total_UPrice)
	SELECT	
		 pharmacy_id,				  
		 drug_name,						  
		 ndc,							  
		 SUM(pack_size) as Total_PkSize,					  
		 0.0					  
		 FROM [dbo].[inventory] 
		 WHERE 	pharmacy_id = 1417 --@pharmacy_id 
		 AND  is_deleted = 0
		 AND pack_size > 0 
		 AND  (drug_name LIKE '%'+ISNULL(@SearchString,drug_name)+'%' OR ndc LIKE '%'+ISNULL(@SearchString,ndc)+'%')
		 GROUP BY pharmacy_id,ndc, drug_name


		 -- update the total price from a NDC from inventory table
		 UPDATE  tempinv SET    
				tempinv.Total_UPrice = tempinv.Total_PkSize * inv.price
				FROM #TEMP_INVENTORY tempinv
				INNER JOIN inventory inv ON tempinv.ndc = inv.ndc

		

		 -- COUNT RECORD
		 SELECT @count= COUNT(*) FROM #TEMP_INVENTORY 

		 -- SELECT RECORD FROM TEMP TABLE
		 SELECT
		 pharmacy_id					  AS PharmacyId,
		 drug_name						  AS DrugName,
		 ndc							  AS NDC,
		 Total_PkSize					  AS PackSize,
		 Total_UPrice					  AS Price,
		 @count                           As Count
		 FROM #TEMP_INVENTORY
		  ORDER BY Total_UPrice desc
		 OFFSET  @PageSize * (@PageNumber - 1)   ROWS
         FETCH NEXT @PageSize ROWS ONLY	

		 -- drop temporary table
		 DROP TABLE #TEMP_INVENTORY
  END




GO
/****** Object:  StoredProcedure [dbo].[SP_inventoryList_bk_04042019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================

-- Author:      Priyanka Chandak

-- Create date: 06-04-2018

-- Description: SP to show inventory list with pagination and serarching

-- exec SP_inventoryList1 1417,100,1,'test','1'

-- exec SP_inventoryList 11,10,1,''

-- =============================================



 CREATE PROC [dbo].[SP_inventoryList_bk_04042019]

  @pharmacy_id  int,

  @PageSize		int,

  @PageNumber    int,

  @SearchString  nvarchar(100)=null,

  @strength      nvarchar(100)=null



	AS

   BEGIN

   DECLARE @count int;



--	select * from inventory where ndc = 116200116 and is_deleted = 0



CREATE TABLE #TEMP_INVENTORY(

	pharmacy_id		INT,

	drug_name		NVARCHAR(2000),

	ndc				BIGINT,

	Total_PkSize	DECIMAL(10,2),

	Total_UPrice	DECIMAL(18,2),

	strength		NVARCHAR(1000),

	form_code		NVARCHAR(1000),

	ndc_packsize	NVARCHAR(1000),

	pack_code		NVARCHAR(1000),

)

-- SELECT @strength



	INSERT INTO #TEMP_INVENTORY(pharmacy_id,drug_name,ndc,Total_PkSize,Total_UPrice,strength,form_code,ndc_packsize,pack_code)

	SELECT	

		 pharmacy_id       AS pharmacy_id,				  

		 drug_name		   AS drug_name,						  

		 ndc			   AS ndc,		

		-- pack_size       AS 	 Total_PkSize,				  

		SUM(pack_size)     AS Total_PkSize,					  

		 0.0		       AS Total_UPrice,

		 ''				AS strength,

		 ''			AS form_code,

		 ''			AS ndc_packsize,

		 ''			AS pack_code

		 FROM [dbo].[inventory] 

		 WHERE pharmacy_id = @pharmacy_id

		 AND  is_deleted = 0

		 AND pack_size > 0 

		 AND 

		 ((IsNull(@SearchString,'')='' and IsNull(@strength,'')='' and  1=1)

		 or (IsNull(@strength,'')<>'' and IsNull(@SearchString,'')='' and [Strength] LIKE '%' + @strength+'%' ) 

		or (IsNull(@SearchString,'')<>'' and IsNull(@strength,'')='' and (drug_name LIKE '%'+ISNULL(@SearchString,drug_name)+'%' OR

			(ndc LIKE '%'+ISNULL(@SearchString,ndc)+'%'))) 

		or(IsNull(@SearchString,'')<>'' and IsNull(@strength,'')<>''and (drug_name LIKE '%'+ISNULL(@SearchString,drug_name)+'%' OR

			(ndc LIKE '%'+ISNULL(@SearchString,ndc)+'%')) and [Strength] LIKE '%' + @strength+'%')	 

				)		

	  GROUP BY pharmacy_id,ndc, drug_name 



	 		

		 -- update the total price  and Pack Size from a NDC from inventory table

		 UPDATE  tempinv SET    

				tempinv.Total_UPrice = tempinv.Total_PkSize * ISNULL(inv.price,0),

				tempinv.ndc_packsize = inv.NDC_Packsize

				--tempinv.strength  = inv.Strength

				FROM #TEMP_INVENTORY tempinv

				INNER JOIN inventory inv ON tempinv.ndc = inv.ndc



		-- Update the Form code of drug and Strength from edi_inventory table

		 UPDATE  tempinv1 SET    

					tempinv1.form_code = edi_inv.PID_Dosage_Form_Code,

					tempinv1.strength  = edi_inv.PID_Strength,

					tempinv1.pack_code  = edi_inv.PO4_Pack_code

				FROM #TEMP_INVENTORY tempinv1

				INNER JOIN edi_inventory edi_inv ON 

				---tempinv1.ndc = CONVERT(BIGINT, ISNULL(edi_inv.LIN_NDC,0))

				edi_inv.LIN_NDC	 = right('00000000000'+cast(tempinv1.ndc as varchar(11)),11)



		 -- COUNT RECORD

		 SELECT @count= COUNT(*) FROM #TEMP_INVENTORY 



		 -- SELECT RECORD FROM TEMP TABLE

		 SELECT

		 pharmacy_id					  AS PharmacyId,

		 drug_name						  AS DrugName,

		 ndc							  AS NDC,

		 Total_PkSize					  AS PackSize,

		 Total_UPrice					  AS Price,

		 strength						  AS Strength,

		 form_code						  AS FormCode,

		 ndc_packsize					  AS NdcPacksize,

		 pack_code						  AS Packcode,		

		 @count                           As Count

		 FROM #TEMP_INVENTORY

		  ORDER BY Total_UPrice desc

		 OFFSET  @PageSize * (@PageNumber - 1)   ROWS

         FETCH NEXT @PageSize ROWS ONLY	



		 -- drop temporary table

		 DROP TABLE #TEMP_INVENTORY

  END





  --go



  --exec SP_inventoryList1 1417,10,1,'','1'

  --go





GO
/****** Object:  StoredProcedure [dbo].[SP_inventoryList1]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 06-04-2018
-- Description: SP to show inventory list with pagination and serarching
-- exec SP_inventoryList1 1417,100,1,'',''
-- exec SP_inventoryList 1417,100,1,'TEST'
-- =============================================

CREATE PROC [dbo].[SP_inventoryList1]
  @pharmacy_id  int,
  @PageSize		int,
  @PageNumber    int,
  @SearchString  nvarchar(100)=null,
  @strength      nvarchar(100)=null

	AS
   BEGIN
   DECLARE @count int;

--	select * from inventory where ndc = 116200116 and is_deleted = 0

CREATE TABLE #TEMP_INVENTORY(
	pharmacy_id		INT,
	drug_name		NVARCHAR(2000),
	ndc				BIGINT,
	Total_PkSize	DECIMAL(10,2),
	Total_UPrice	DECIMAL(10,2),
	strength		NVARCHAR(1000),
	form_code		NVARCHAR(1000),
	ndc_packsize	NVARCHAR(1000),
	pack_code		NVARCHAR(1000),
)
-- SELECT @strength

	INSERT INTO #TEMP_INVENTORY(pharmacy_id,drug_name,ndc,Total_PkSize,Total_UPrice,strength,form_code,ndc_packsize,pack_code)
	SELECT	
		 pharmacy_id       AS pharmacy_id,				  
		 drug_name		   AS drug_name,						  
		 ndc			   AS ndc,		
		-- pack_size       AS 	 Total_PkSize,				  
		SUM(pack_size)     AS Total_PkSize,					  
		 0.0		       AS Total_UPrice,
		 ''				AS strength,
		 '0'			AS form_code,
		 '0'			AS ndc_packsize,
		 '0'			AS pack_code
		 FROM [dbo].[inventory] 
		 WHERE pharmacy_id = @pharmacy_id 
		 AND  is_deleted = 0
		 AND pack_size > 0 
		 AND 
		 ((IsNull(@SearchString,'')='' and IsNull(@strength,'')='' and  1=1)
		 or (IsNull(@strength,'')<>'' and IsNull(@SearchString,'')='' and [Strength] LIKE '%' + @strength+'%' ) 
		or (IsNull(@SearchString,'')<>'' and IsNull(@strength,'')='' and (drug_name LIKE '%'+ISNULL(@SearchString,drug_name)+'%' OR
			(ndc LIKE '%'+ISNULL(@SearchString,ndc)+'%'))) 
		or(IsNull(@SearchString,'')<>'' and IsNull(@strength,'')<>''and (drug_name LIKE '%'+ISNULL(@SearchString,drug_name)+'%' OR
			(ndc LIKE '%'+ISNULL(@SearchString,ndc)+'%')) and [Strength] LIKE '%' + @strength+'%')	 
				)		
	  GROUP BY pharmacy_id,ndc, drug_name 


	 		
		 -- update the total price  and Pack Size from a NDC from inventory table
		 UPDATE  tempinv SET    
				tempinv.Total_UPrice = tempinv.Total_PkSize * inv.price,
				tempinv.ndc_packsize = inv.NDC_Packsize
				--tempinv.strength  = inv.Strength
				FROM #TEMP_INVENTORY tempinv
				INNER JOIN inventory inv ON tempinv.ndc = inv.ndc

		-- Update the Form code of drug and Strength from edi_inventory table
		 UPDATE  tempinv1 SET    
					tempinv1.form_code = edi_inv.PID_Dosage_Form_Code,
					tempinv1.strength  = edi_inv.PID_Strength,
					tempinv1.pack_code  = edi_inv.PO4_Pack_code
				FROM #TEMP_INVENTORY tempinv1
				INNER JOIN edi_inventory edi_inv ON 
				---tempinv1.ndc = CONVERT(BIGINT, ISNULL(edi_inv.LIN_NDC,0))
				edi_inv.LIN_NDC	 = right('00000000000'+cast(tempinv1.ndc as varchar(11)),11)

		 -- COUNT RECORD
		 SELECT @count= COUNT(*) FROM #TEMP_INVENTORY 

		 -- SELECT RECORD FROM TEMP TABLE
		 SELECT
		 pharmacy_id					  AS PharmacyId,
		 drug_name						  AS DrugName,
		 ndc							  AS NDC,
		 Total_PkSize					  AS PackSize,
		 Total_UPrice					  AS Price,
		 strength						  AS Strength,
		 form_code						  AS FormCode,
		 ndc_packsize					  AS NdcPacksize,
		 pack_code						  AS Packcode,		
		 @count                           As Count
		 FROM #TEMP_INVENTORY
		  ORDER BY Total_UPrice desc
		 OFFSET  @PageSize * (@PageNumber - 1)   ROWS
         FETCH NEXT @PageSize ROWS ONLY	

		 -- drop temporary table
		 DROP TABLE #TEMP_INVENTORY
  END


  --go

  --exec SP_inventoryList1 1417,10,1,'','1'
  --go



GO
/****** Object:  StoredProcedure [dbo].[SP_InventorySummary]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- SP_InventorySummary 1417,2

CREATE PROC [dbo].[SP_InventorySummary]
(
@pharmacyId     INT,
@summaryby		INT

)
AS
BEGIN

CREATE TABLE #Temp_inventorysummary
(
Price    decimal(18,2),
WeekMonth  nvarchar(100),
year       int

)
------------------------------Show weekly inventory summary -----------------------------------------------------

	IF(@summaryby =1)
		BEGIN
		    INSERT INTO  #Temp_inventorysummary(WeekMonth,Price)
			EXEC WeeklyInventorySummary  @pharmacyId
		END

------------------------------Show Monthly inventory summary-----------------------------------------------------

	ELSE IF(@summaryby =2)
		BEGIN 
		 INSERT INTO  #Temp_inventorysummary(WeekMonth,Price)
		  EXEC MonthlyInventorySummary  @pharmacyId
		END
------------------------------Show Yearly inventory summary(5 Years)-----------------------------------------------------

	ELSE IF(@summaryby =3)
		BEGIN 
		 INSERT INTO  #Temp_inventorysummary(year,Price)
		  EXEC YearlyInventorySummary  @pharmacyId

		END


	SELECT * FROM #Temp_inventorysummary
END

--select* from inventory

GO
/****** Object:  StoredProcedure [dbo].[SP_lowstockReportList]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Create date: 06-04-2018
-- Description: SP to show lowstockreport list with pagination and serarching
-- SP_lowstockReportList 12,0,1,''
-- =============================================


CREATE PROC [dbo].[SP_lowstockReportList]
  @pharmacy_id  int,
  @PageSize		int,
  @PageNumber    int,
  @SearchString  nvarchar(100)=null

	AS
   BEGIN
  DECLARE @count int;          
	 DECLARE @expired_month INT      
	 SELECT @expired_month = [expiry_month] FROM [Inv_Exp_Config]      
          
 CREATE TABLE #Temp_lowstockreport(      
	  InventoryId INT,       
	  PharmacyId INT,      
	  WholesalerId INT,      
	  MedicineName NVARCHAR(500),      
	  QuantityOnHand DECIMAL(10,2),      
	  OptimalQuantity DECIMAL(10,2),      
	  ExpirtyDate  DATETIME,      
	  Price  DECIMAL(12,2),      
	  NDC BIGINT,      
	  Strength   NVARCHAR(100),      
	  Count  INT      
 )      
      
	INSERT INTO  #Temp_lowstockreport(InventoryId, PharmacyId,WholesalerId,MedicineName,QuantityOnHand,OptimalQuantity,ExpirtyDate,Price,NDC,Strength)      
      
    EXEC SP_underSupply_rawdata @pharmacy_id       

	SELECT 
	  InventoryId ,       
	  PharmacyId ,      
	  WholesalerId ,      
	  MedicineName ,      
	  QuantityOnHand ,      
	  OptimalQuantity ,      
	  ExpirtyDate,      
	  Price ,      
	  NDC ,      
	  Strength ,      
     COUNT(1) OVER () AS Count
	 FROM #Temp_lowstockreport  
	   WHERE (      
		(MedicineName LIKE '%'+ISNULL(@SearchString,MedicineName)+'%')        
		OR      
		(NDC LIKE '%'+ISNULL(@SearchString,NDC)+'%')         
	   )      AND ISNULL(QuantityOnHand,0) >  0
	 ORDER BY WholesalerId      
	 OFFSET  @PageSize * (@PageNumber - 1)   ROWS    
     FETCH NEXT IIF(@PageSize = 0, 100000, @PageSize) ROWS ONLY   
	
	END	 
	


	





GO
/****** Object:  StoredProcedure [dbo].[SP_lowstockReportList_BK13032019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Create date: 06-04-2018
-- Description: SP to show lowstockreport list with pagination and serarching
-- SP_lowstockReportList_BK13032019 1417,100,1,''
-- =============================================


CREATE PROC [dbo].[SP_lowstockReportList_BK13032019]
  @pharmacy_id  int,
  @PageSize		int,
  @PageNumber    int,
  @SearchString  nvarchar(100)=null

	AS
   BEGIN
    DECLARE @count int;   	
	DECLARE @expired_month INT
	SELECT @expired_month = [expiry_month] FROM [Inv_Exp_Config]

	--drop table #Temp_lowstockreport
	CREATE TABLE #Temp_lowstockreport(
		InventoryId	INT,	
		PharmacyId INT,
		WholesalerId INT,
		MedicineName NVARCHAR(500),
		QuantityOnHand DECIMAL(10,2),
		OptimalQuantity DECIMAL(10,2),
		ExpirtyDate  DATETIME,
		Price  DECIMAL(12,2),
		NDC BIGINT,
		Strength   NVARCHAR(100),
		Count  INT
	)

	INSERT INTO  #Temp_lowstockreport(InventoryId, PharmacyId,WholesalerId,MedicineName,QuantityOnHand,OptimalQuantity,ExpirtyDate,Price,NDC,Strength)

		EXEC SP_underSupply_rawdata @pharmacy_id

		--DELETE THE RECORD WITH PACK SIZE OF 0
		delete from #Temp_lowstockreport where ISNULL(QuantityOnHand,0) =  0

  
	
   SELECT  @count = ISNULL (COUNT(*),0) FROM #Temp_lowstockreport  WHERE (
				(MedicineName LIKE '%'+ISNULL(@SearchString,MedicineName)+'%')	OR
				(NDC LIKE '%'+ISNULL(@SearchString,NDC)+'%')	
				)

     UPDATE #Temp_lowstockreport SET Count=@count

	  IF @PageSize > 0
	 BEGIN
	 SELECT * FROM #Temp_lowstockreport 
	 WHERE (
				(MedicineName LIKE '%'+ISNULL(@SearchString,MedicineName)+'%')		
				OR
				(NDC LIKE '%'+ISNULL(@SearchString,NDC)+'%')			
			)
		 ORDER BY WholesalerId
		 OFFSET  @PageSize * (@PageNumber - 1)   ROWS
        FETCH NEXT @PageSize ROWS ONLY

	END
	ELSE
	BEGIN
	 SELECT * FROM #Temp_lowstockreport 
	 WHERE (
				(MedicineName LIKE '%'+ISNULL(@SearchString,MedicineName)+'%')		
				OR
				(NDC LIKE '%'+ISNULL(@SearchString,NDC)+'%')			
			)
		 ORDER BY WholesalerId
	
	END	 
	


	
	 
  END




GO
/****** Object:  StoredProcedure [dbo].[SP_ManualInvoiceDetails]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================          
          
-- Create date: 11-03-2019          
-- Created By: Humera Sheikh        
-- Description: SP to show Manual Invoice  Details     
-- EXEC SP_ManualInvoiceDetails 13          
-- =============================================          
          
                  
 create PROC [dbo].[SP_ManualInvoiceDetails]    
               
   @shipment_id int    
          
  AS          
          
   BEGIN  
      SELECT        
		ship_dt.shippment_id AS shippingId,  
		ship_dt.ndc AS NDC,         
		ship_dt.quantity AS quantity,    
		ship_dt.unit_price AS unitPrice,           
		ship_dt.drug_name AS drugName,      
		ship_dt.lot_number AS lotNumber,    
		ship_dt.exipry_date AS   exipryDate, 
		ship_dt.strength AS Strength,
		ship_dt.pack_size AS PackSize,
		ship.created_on AS PurchaseDate,
		phs.pharmacy_name AS SellerPharmacyName,
		php.pharmacy_name AS PurchasePharmacyName,   
		ship_dt.quantity * ship_dt.unit_price AS TotalCost
	 FROM [dbo].[shippmentdetails] ship_dt   
	 INNER JOIN [dbo].[shippment] ship ON ship_dt. shippment_id = ship.shippment_id
	 INNER JOIN [dbo].[pharmacy_list] php ON  php.pharmacy_id = ship.purchaser_pharmacy_id
	 INNER JOIN [dbo].[pharmacy_list] phs ON  phs.pharmacy_id = ship.seller_pharmacy_id
	 WHERE ship_dt.shippment_id = @shipment_id    

   END 
GO
/****** Object:  StoredProcedure [dbo].[SP_medicineList]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author:      lata bisht
-- Create date: 11-04-2018
-- Description: SP to show medicine list with pagination and serarching
--SP_medicineList 1417,2,1,''
-- =============================================

CREATE PROC [dbo].[SP_medicineList]
  @pharmacy_id  int,
  @PageSize		int,
  @PageNumber    int,
  @SearchString  nvarchar(100)=null

	AS
   BEGIN
   DECLARE @count int;
  
  	SELECT
	     medicine_id					  AS MedicineId,
		 pharmacy_id					  AS PharmacyId,
		 drug_name						  AS DrugName,
		 ndc_code							  AS NdcCode,
		 generic_code					  AS GenericCode,
		 --pack_size						  AS PackSize,		
		 description                      AS Description
		-- @count                           As Count
		  INTO #Temp_Table     
		 FROM [dbo].[medicine]
		 WHERE 	pharmacy_id = @pharmacy_id AND is_deleted IS NULL
		 
		   SELECT @count=  IsNull(COUNT(*),0) FROM #Temp_Table where (DrugName LIKE '%'+ISNULL(@SearchString,DrugName)+'%' OR
		 NdcCode LIKE '%'+ISNULL(@SearchString,NdcCode)+'%')
		 
		 select *,@count AS Count from #Temp_Table
		 where (DrugName LIKE '%'+ISNULL(@SearchString,DrugName)+'%' OR
		 NdcCode LIKE '%'+ISNULL(@SearchString,NdcCode)+'%')
		 ORDER BY MedicineId desc
		 OFFSET  @PageSize * (@PageNumber - 1)   ROWS
         FETCH NEXT @PageSize ROWS ONLY	


  END

  --exec SP_medicineList 1,10,1,''

  --SELECT * FROM MEDICINE



GO
/****** Object:  StoredProcedure [dbo].[SP_message_status_update]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author: Sagar Sharma     
-- Create date: 14-05-2018
-- Description: SP to Update the inventory after RX30 file.
-- =============================================

CREATE PROC [dbo].[SP_message_status_update]
	@from_ph_id			INT,
	@to_ph_id			INT
	


	AS
   BEGIN
   UPDATE ph_messageboard 
   SET status='read' WHERE
   (from_ph_id = @from_ph_id OR from_ph_id = @to_ph_id) AND (to_ph_id = @to_ph_id OR to_ph_id = @from_ph_id)
   
  END



GO
/****** Object:  StoredProcedure [dbo].[SP_negative_qty_onshelf]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Create date: 10-05-2018
-- Description: SP to show negative quantity on shelf
-- SP_negative_qty_onshelf 13
-- =============================================
CREATE PROC [dbo].[SP_negative_qty_onshelf]
@pharmacy_id int

AS
BEGIN
	/*
	select top 3 
	drug_name   AS DrugName,
	ndc			AS NDC,
	pack_size   AS PackSize,
	price		AS UnitPrice
	 from inventory
	 where pack_size<0 AND pharmacy_id = @pharmacy_id AND is_deleted=0
	 order by pack_size desc
	 */
	 SELECT TOP 3 
		inv.drug_name   AS DrugName,		
		pro.ndc			AS NDC,
		pro.qty_reorder   AS PackSize,
		inv.price		AS UnitPrice
	FROM pending_reorder pro
		CROSS APPLY(SELECT TOP 1 i.ndc, i.price,i.drug_name FROM inventory i WHERE  i.is_deleted= 0 AND i.pharmacy_id = @pharmacy_id AND i.ndc = pro.ndc) inv 	
	WHERE pro.qty_reorder > 0 AND  pro.pharmacy_id = @pharmacy_id 
	order by pro.qty_reorder desc
END

--exec SP_negative_qty_onshelf 1





GO
/****** Object:  StoredProcedure [dbo].[SP_optim_inventory_overstock]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 16-04-2018
-- Description: SP to for oversupply with pagination
-- =============================================

CREATE PROC [dbo].[SP_optim_inventory_overstock]
  @pharmacy_id			int,
  @PageSize			    int,
  @PageNumber			int,
  @SearchString		    nvarchar(100)= ''
  AS
   BEGIN

   -- declaring variables
   DECLARE @pharma_id int
   set @pharma_id = @pharmacy_id
   Declare @page_size int
   set @page_size = @PageSize
   Declare @page_number int
   set @page_number = @PageNumber
   Declare @search_string nvarchar(100)
   set @search_string = @SearchString
    
    CREATE TABLE #Temp_statusclassification
	(InventoryId		 INT,
	 PharmacyId			 INT,
	 WholesalerId		 INT, 
	 MedicineName		 NVARCHAR(500), 
	 QuantityOnHand		 INT,
	 OptimalQuantity	 INT, 
	 OverStocksSurplus	 DECIMAL(10,2),	
	 NDC			     BIGINT,
	 Count				 INT,
	 Price				 MONEY)

	INSERT INTO #Temp_statusclassification (InventoryId,PharmacyId,WholesalerId,MedicineName,QuantityOnHand,OptimalQuantity,NDC,Price)
	 SELECT
	     inventory_id					  AS InventoryId,
		 pharmacy_id					  AS PharmacyId,
		 wholesaler_id                    AS WholesalerId,
		 drug_name						  AS MedicineName,
		 pack_size						  AS QuantityOnHand,
		 dbo.FN_calculate_optimum_qty(ndc,@pharmacy_id)AS OptimalQuantity,
		 ndc							  AS NDC,
		 price							  AS Price
	 FROM [dbo].[inventory] 
	 WHERE 	pharmacy_id = @pharma_id 

	 CREATE INDEX temp_status_index ON #Temp_statusclassification (InventoryId);

	  --select * from #Temp_statusclassification
	 UPDATE #Temp_statusclassification SET [OverStocksSurplus]=(CASE WHEN ((QuantityOnHand/100)>OptimalQuantity) THEN (QuantityOnHand/100)
															ELSE 0.00 END)  
   DECLARE @count int;
   SELECT @count=  IsNull(COUNT(*),0) FROM #Temp_statusclassification where  OverStocksSurplus > 0

	SELECT InventoryId,PharmacyId,WholesalerId,MedicineName,QuantityOnHand,OptimalQuantity,NDC,Price,OverStocksSurplus,@count AS Count
	FROM #Temp_statusclassification 
	WHERE 
		 pharmacyId=@pharma_id AND OverStocksSurplus > 0
		 AND (MedicineName LIKE '%'+ISNULL(@search_string,MedicineName)+'%' OR
		 NDC LIKE '%'+ISNULL(@search_string,NDC)+'%')
		 ORDER BY InventoryId 
		 OFFSET  @page_size * (@page_number - 1)   ROWS
		 FETCH NEXT @page_size ROWS ONLY	

		 DROP TABLE #Temp_statusclassification	
		 	END
			--EXEC [SP_optim_inventory_overstock] 1,10,1,''
SET NOCOUNT OFF;





GO
/****** Object:  StoredProcedure [dbo].[SP_overstock]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 05-04-2018
-- Description: SP to for oversupply
--EXEC [SP_overstock] 12
-- =============================================

CREATE PROC [dbo].[SP_overstock]
  @pharmacy_id			int
 
  AS
   BEGIN


	 DECLARE @cdate DATETIME = DATEADD(month, -3, GETDATE()) 

	;WITH overstock AS (
		SELECT
	     inv.inventory_id					  AS InventoryId,
		 inv.pharmacy_id					  AS PharmacyId,
		 inv.wholesaler_id                    AS WholesalerId,
		 inv.drug_name						  AS MedicineName,
		 inv.pack_size						  AS QuantityOnHand,
		 /*dbo.FN_calculate_optimum_qty(ndc,@pharmacy_id)AS OptimalQuantity,*/
		 /*ROUND(opt,0)         AS OptimalQuantity,*/
		 opt         AS OptimalQuantity,
		 CAST((CASE WHEN ((inv.pack_size/100)>opt) THEN (inv.pack_size/100) ELSE 0.00 END) as int ) AS OverStocksSurplus,
		
		 inv.ndc							  AS NDC,
		 inv.price							  AS Price
		
	 FROM [dbo].[inventory] inv
	  CROSS APPLY (  
			SELECT SUM(qty_disp) / 3 AS opt  
			FROM [dbo].[RX30_inventory] rx   
			WHERE rx.ndc = inv.ndc AND rx.pharmacy_id = @pharmacy_id AND rx.created_on >= @cdate AND rx.is_deleted IS NULL  
	   ) rx  

	 WHERE 	inv.pharmacy_id = @pharmacy_id AND inv.pack_size > 0 AND rx.opt > 0
	)		

	SELECT InventoryId,PharmacyId,WholesalerId,MedicineName,QuantityOnHand,OptimalQuantity,NDC,Price,OverStocksSurplus
	FROM overstock WHERE  OverStocksSurplus > 0
	
			
END
		





GO
/****** Object:  StoredProcedure [dbo].[SP_overstock_bk_06102019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 05-04-2018
-- Description: SP to for oversupply
-- =============================================

CREATE PROC [dbo].[SP_overstock_bk_06102019]
  @pharmacy_id			int
 
  AS
   BEGIN

    CREATE TABLE #Temp_statusclassification
	(InventoryId		 INT,
	 PharmacyId			 INT,
	 WholesalerId		 INT, 
	 MedicineName		 NVARCHAR(500), 
	 QuantityOnHand		 INT,
	 OptimalQuantity	 INT, 
	 OverStocksSurplus	 DECIMAL(10,2),	
	 NDC			     BIGINT,
	 Count				 INT,
	 Price				 MONEY)

	INSERT INTO #Temp_statusclassification (InventoryId,PharmacyId,WholesalerId,MedicineName,QuantityOnHand,OptimalQuantity,NDC,Price)
	 SELECT
	     inventory_id					  AS InventoryId,
		 pharmacy_id					  AS PharmacyId,
		 wholesaler_id                    AS WholesalerId,
		 drug_name						  AS MedicineName,
		 pack_size						  AS QuantityOnHand,
		 dbo.FN_calculate_optimum_qty(ndc,@pharmacy_id)AS OptimalQuantity,		
		 ndc							  AS NDC,
		 price							  AS Price
		
	 FROM [dbo].[inventory] 
	 WHERE 	pharmacy_id = @pharmacy_id 
	 UPDATE #Temp_statusclassification SET [OverStocksSurplus]=(CASE WHEN ((QuantityOnHand/100)>OptimalQuantity) THEN (QuantityOnHand/100)
															ELSE 0.00 END)    

	SELECT InventoryId,PharmacyId,WholesalerId,MedicineName,QuantityOnHand,OptimalQuantity,NDC,Price,OverStocksSurplus
	FROM #Temp_statusclassification 
	WHERE 
		 pharmacyId=@pharmacy_id AND OverStocksSurplus > 0		


		 DROP TABLE #Temp_statusclassification	
		 	END
			--EXEC [SP_overstock] 1417





GO
/****** Object:  StoredProcedure [dbo].[SP_overstock_dashboard]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================
-- Create date: 05-04-2018
-- Description: SP to for oversupply
-- =============================================

CREATE PROC [dbo].[SP_overstock_dashboard]
  @pharmacy_id Int,
  @pagesize INT,
  @pagenumber INT

  AS
   BEGIN

    CREATE TABLE #Temp_statusclassification
	(InventoryId		 INT,
	 PharmacyId			 INT,
	 WholesalerId		 INT, 
	 MedicineName		 NVARCHAR(500), 
	 QuantityOnHand		 INT,
	 OptimalQuantity	 INT, 
	 OverStocksSurplus	 DECIMAL(10,2),	
	 NDC			     BIGINT,
	 Count				 INT,
	 Price				 MONEY)

	INSERT INTO #Temp_statusclassification (InventoryId,PharmacyId,WholesalerId,MedicineName,QuantityOnHand,OptimalQuantity,NDC,Price)
	 SELECT
	     inventory_id					  AS InventoryId,
		 pharmacy_id					  AS PharmacyId,
		 wholesaler_id                    AS WholesalerId,
		 drug_name						  AS MedicineName,
		 pack_size						  AS QuantityOnHand,
		 dbo.FN_calculate_optimum_qty(ndc,@pharmacy_id)AS OptimalQuantity,		
		 ndc							  AS NDC,
		 price							  AS Price
		
	 FROM [dbo].[inventory] 
	 WHERE 	pharmacy_id = @pharmacy_id 

	 UPDATE #Temp_statusclassification 
	 SET [OverStocksSurplus]=(CASE WHEN ((QuantityOnHand/100)>OptimalQuantity) THEN (QuantityOnHand/100)
															ELSE 0.00 END)    

	SELECT InventoryId,PharmacyId,WholesalerId,MedicineName,QuantityOnHand,OptimalQuantity,NDC,Price,OverStocksSurplus
	FROM #Temp_statusclassification 
	WHERE 
	pharmacyId=@pharmacy_id AND OverStocksSurplus > 0	
	Order by OverStocksSurplus DESC
	OFFSET  @pagesize * (@pagenumber - 1) ROWS
    FETCH NEXT @pagesize ROWS ONLY

	DROP TABLE #Temp_statusclassification	
	END
			--EXEC [SP_overstock] 1417





GO
/****** Object:  StoredProcedure [dbo].[SP_OverSupply]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
-- =============================================

-- Create date: 27-03-2018

-- Description: SP to show oversupply(forcasting) of medicines
--EXEC SP_OverSupply 12,0,1,''
-- =============================================


CREATE PROC [dbo].[SP_OverSupply]
  @pharmacy_id int,
  @PageSize		int,
  @PageNumber    int,  
  @SearchString  nvarchar(100)=null

  AS
   BEGIN

       
 DECLARE @loc_pharmacy_id INT,  @loc_PageSize	INT, @loc_PageNumber    INT,   @loc_SearchString  NVARCHAR(100)
 SET @loc_pharmacy_id =		@pharmacy_id
 SET @loc_PageSize =		@PageSize
 SET @loc_PageNumber =		@PageNumber
 SET @loc_SearchString =	@SearchString

  
 DECLARE @expired_month INT  
 SELECT @expired_month = [expiry_month] FROM [Inv_Exp_Config]  
   
 DECLARE @cdate DATETIME = DATEADD(month, -3, GETDATE())  
  
 ;WITH OverSupply AS (  
    SELECT    
		pharmacy_id       AS PharmacyId,  
		ISNULL(wholesaler_id,0)          AS WholesalerId,  
		drug_name        AS MedicineName,  
		ndc         AS NDC,  
		pack_size        AS QuantityOnHand,  
		ROUND(opt,0)         AS OptimalQuantity,  
		strength        AS Strength,  
		EOMONTH(DATEADD(month, @expired_month, ISNULL(created_on,GETDATE()))) AS ExpirtyDate,  
		inv.price         AS Price  
	   FROM [dbo].[inventory] inv  
	   CROSS APPLY (  
			SELECT SUM(qty_disp) / 3 AS opt  
			FROM [dbo].[RX30_inventory] rx   
			WHERE rx.ndc = inv.ndc AND rx.pharmacy_id = @loc_pharmacy_id AND rx.created_on >= @cdate AND rx.is_deleted IS NULL  
	   ) rx  
	   		
	   WHERE   
	   (inv.pharmacy_id = @loc_pharmacy_id) AND (ISNULL(inv.is_deleted,0) = 0) AND (ISNULL(inv.pack_size,0) > 0)   AND rx.opt > 0
	 )  
	
	SELECT   
	  PharmacyId,  
	  WholesalerId,  
	  MedicineName,  
	  NDC,  
	  QuantityOnHand,  
	  OptimalQuantity,  
	  ExpirtyDate,  
	  Strength,  
	  Price,  
	  COUNT(1) OVER () AS Count  
	FROM OverSupply  
	 WHERE ((MedicineName LIKE '%'+ISNULL(@loc_SearchString,MedicineName)+'%')  
	  OR (NDC LIKE '%'+ISNULL(@SearchString,NDC)+'%'))  
	  AND (ExpirtyDate > GETDATE()) AND (QuantityOnHand > (OptimalQuantity * 1.3))     
	 ORDER BY WholesalerId, MedicineName  
	 OFFSET  @loc_PageSize * (@loc_PageNumber - 1)   ROWS  
	 FETCH NEXT IIF(@loc_PageSize = 0, 100000, @loc_PageSize) ROWS ONLY  
   
  END




GO
/****** Object:  StoredProcedure [dbo].[SP_OverSupply_bk_06102019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================

-- Create date: 27-03-2018

-- Description: SP to show oversupply(forcasting) of medicines
--EXEC SP_OverSupply 12,0,1,''
-- =============================================



CREATE PROC [dbo].[SP_OverSupply_bk_06102019]

  @pharmacy_id int,
  @PageSize		int,
  @PageNumber    int,  
  @SearchString  nvarchar(100)=null

  AS

   BEGIN

      DECLARE @count int;    
  
 DECLARE @expired_month INT  
 SELECT @expired_month = [expiry_month] FROM [Inv_Exp_Config]  
   
 DECLARE @cdate DATETIME = DATEADD(month, -3, GETDATE())  
  
 ;WITH OverSupply AS (  
    SELECT    
		pharmacy_id       AS PharmacyId,  
		ISNULL(wholesaler_id,0)          AS WholesalerId,  
		drug_name        AS MedicineName,  
		ndc         AS NDC,  
		pack_size        AS QuantityOnHand,  
		ROUND(opt,0)         AS OptimalQuantity,  
		strength        AS Strength,  
		EOMONTH(DATEADD(month, @expired_month, ISNULL(created_on,GETDATE()))) AS ExpirtyDate,  
		inv.price         AS Price  
	   FROM [dbo].[inventory] inv  
	   CROSS APPLY (  
			SELECT SUM(qty_disp) / 3 AS opt  
			FROM [dbo].[RX30_inventory] rx   
			WHERE rx.ndc = inv.ndc AND rx.pharmacy_id = inv.pharmacy_id AND rx.created_on >= @cdate AND rx.is_deleted IS NULL  
	   ) rx  
  
	   WHERE   
	   (pharmacy_id = @pharmacy_id) AND (ISNULL(is_deleted,0) = 0) AND (ISNULL(pack_size,0) > 0)  
	 )  
	SELECT   
	  PharmacyId,  
	  WholesalerId,  
	  MedicineName,  
	  NDC,  
	  QuantityOnHand,  
	  OptimalQuantity,  
	  ExpirtyDate,  
	  Strength,  
	  Price,  
	  COUNT(1) OVER () AS Count  
	FROM OverSupply  
	 WHERE ((MedicineName LIKE '%'+ISNULL(@SearchString,MedicineName)+'%')  
	  OR (NDC LIKE '%'+ISNULL(@SearchString,NDC)+'%'))  
	  AND (ExpirtyDate > GETDATE()) AND (QuantityOnHand > (OptimalQuantity * 1.3))     
	 ORDER BY WholesalerId, MedicineName  
	 OFFSET  @PageSize * (@PageNumber - 1)   ROWS  
	 FETCH NEXT IIF(@PageSize = 0, 100000, @PageSize) ROWS ONLY  
  
  

  END







GO
/****** Object:  StoredProcedure [dbo].[SP_OverSupply_BK13031996]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================

-- Create date: 27-03-2018

-- Description: SP to show oversupply(forcasting) of medicines
--EXEC SP_OverSupply_BK13031996 12,40,1,'alp'
-- =============================================



CREATE PROC [dbo].[SP_OverSupply_BK13031996]

  @pharmacy_id int,
  @PageSize		int,
  @PageNumber    int,  
  @SearchString  nvarchar(100)=null

  AS

   BEGIN

    DECLARE @count int;  
	CREATE TABLE #Temp_OverSupply(		
		PharmacyId INT,
		WholesalerId INT,
		MedicineName NVARCHAR(500),
		NDC				BIGINT,
		QuantityOnHand DECIMAL(10,2),
		OptimalQuantity DECIMAL(10,2),
		ExpirtyDate  DATETIME,
		 Strength		NVARCHAR(100),
		Price  DECIMAL(12,2),
		Count  INT
	)
	--DECLARE @

	DECLARE @expired_month INT
	SELECT @expired_month = [expiry_month] FROM [Inv_Exp_Config]

	INSERT INTO  #Temp_OverSupply(PharmacyId,WholesalerId,MedicineName, NDC, QuantityOnHand,Strength,OptimalQuantity,ExpirtyDate,Price)
  	SELECT		
	    
		 pharmacy_id					  AS PharmacyId,
		 ISNULL(wholesaler_id,0)          AS WholesalerId,
		 drug_name						  AS MedicineName,
		 ndc							  AS NDC,
		 pack_size						  AS QuantityOnHand,
		 strength						  AS Strength,
		 --dbo.FN_calculate_optimum_qty(ndc,@pharmacy_id) AS OptimalQuantity,
		 0 AS OptimalQuantity,
		 EOMONTH(DATEADD(month, @expired_month, ISNULL(created_on,GETDATE()))) AS ExpirtyDate,
		 price							  AS Price 
	 FROM [dbo].[inventory] 

	 WHERE 	(
		(pharmacy_id = @pharmacy_id) AND (ISNULL(is_deleted,0) = 0) AND (ISNULL(pack_size,0) > 0)
	 )
	 
	 /*This logic added to avoid calculating Optimum quantity for duplicate ndc*/
	 CREATE TABLE #Temp_OverSupply_OQ(				
		NDC				BIGINT,		
		OptimalQuantity DECIMAL(10,2),
		NDC_Count       INT		
	)

	INSERT INTO #Temp_OverSupply_OQ(NDC,OptimalQuantity,NDC_Count)
		SELECT NDC,0,COUNT(NDC)
		FROM #Temp_OverSupply
		GROUP BY NDC
	
	 /*Update Optimume quantity*/
	 UPDATE #Temp_OverSupply_OQ
		SET OptimalQuantity = dbo.FN_calculate_optimum_qty(NDC,@pharmacy_id)
	
	 UPDATE temp_OS
		SET temp_OS.OptimalQuantity = temp_OSOQ.OptimalQuantity
	 FROM #Temp_OverSupply temp_OS
	 INNER JOIN #Temp_OverSupply_OQ temp_OSOQ ON temp_OSOQ.NDC = temp_OS.NDC	 		
	 
	 /*----------------------------------------------------*/

	--SELECT * FROM #Temp_OverSupply_OQ
	DROP TABLE #Temp_OverSupply_OQ
		  

	 
	
	
		
	SELECT  @count= IsNull (COUNT(*),0) FROM #Temp_OverSupply
	WHERE (
			
			((MedicineName LIKE '%'+ISNULL(@SearchString,MedicineName)+'%')
			 or (NDC LIKE '%'+ISNULL(@SearchString,NDC)+'%'))
			AND (ExpirtyDate > GETDATE()) AND (QuantityOnHand > (OptimalQuantity * 1.3))			
	)

     UPDATE #Temp_OverSupply SET Count=@count
	 
	 IF @PageSize > 0
	 BEGIN
	 SELECT * FROM #Temp_OverSupply 
	 WHERE (
			
			((MedicineName LIKE '%'+ISNULL(@SearchString,MedicineName)+'%')
			 or (NDC LIKE '%'+ISNULL(@SearchString,NDC)+'%'))
			AND (ExpirtyDate > GETDATE()) AND (QuantityOnHand > (OptimalQuantity * 1.3))			
	)
		 ORDER BY WholesalerId		
		 OFFSET  @PageSize * (@PageNumber - 1)   ROWS
        FETCH NEXT @PageSize ROWS ONLY
	END
	ELSE
	BEGIN
	 SELECT * FROM #Temp_OverSupply 
		 WHERE (
			
			((MedicineName LIKE '%'+ISNULL(@SearchString,MedicineName)+'%')
			 or (NDC LIKE '%'+ISNULL(@SearchString,NDC)+'%'))
			AND (ExpirtyDate > GETDATE()) AND (QuantityOnHand > (OptimalQuantity * 1.3))			
	)
		 ORDER BY WholesalerId, MedicineName
	END	 
	
	-- RETURN @var1;



  END



  --select * from inventory where NDC = 169266015





GO
/****** Object:  StoredProcedure [dbo].[SP_OverSupply1]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================

-- Create date: 27-03-2018

-- Description: SP to show oversupply(forcasting) of medicines
--EXEC SP_OverSupply 1417,40,1,'insuli'
-- =============================================



CREATE PROC [dbo].[SP_OverSupply1]

  @pharmacy_id int,
  @PageSize		int,
  @PageNumber    int,  
  @SearchString  nvarchar(100)=null

  AS

   BEGIN

    DECLARE @count int;  
	CREATE TABLE #Temp_OverSupply(		
		PharmacyId INT,
		WholesalerId INT,
		MedicineName NVARCHAR(500),
		NDC				BIGINT,
		QuantityOnHand DECIMAL(10,2),
		OptimalQuantity DECIMAL(10,2),
		ExpirtyDate  DATETIME,
		 Strength		NVARCHAR(100),
		Price  DECIMAL(12,2),
		Count  INT,
		InventoryId  INT
	)
	--DECLARE @

	DECLARE @expired_month INT
	SELECT @expired_month = [expiry_month] FROM [Inv_Exp_Config]

	INSERT INTO  #Temp_OverSupply(InventoryId,PharmacyId,WholesalerId,MedicineName, NDC, QuantityOnHand,Strength,OptimalQuantity,ExpirtyDate,Price)
  	SELECT		
	     inventory_id as InventoryId,
		 pharmacy_id					  AS PharmacyId,
		 ISNULL(wholesaler_id,0)          AS WholesalerId,
		 drug_name						  AS MedicineName,
		 ndc							  AS NDC,
		 pack_size						  AS QuantityOnHand,
		 strength						  AS Strength,
		 --dbo.FN_calculate_optimum_qty(ndc,@pharmacy_id) AS OptimalQuantity,
		 0 AS OptimalQuantity,
		 EOMONTH(DATEADD(month, @expired_month, ISNULL(created_on,GETDATE()))) AS ExpirtyDate,
		 price							  AS Price 
	 FROM [dbo].[inventory] 

	 WHERE 	(
		(pharmacy_id = @pharmacy_id) AND (ISNULL(is_deleted,0) = 0) AND (ISNULL(pack_size,0) > 0)
	 )
	 
	 /*This logic added to avoid calculating Optimum quantity for duplicate ndc*/
	 CREATE TABLE #Temp_OverSupply_OQ(				
		NDC				BIGINT,		
		OptimalQuantity DECIMAL(10,2),
		NDC_Count       INT		
	)

	INSERT INTO #Temp_OverSupply_OQ(NDC,OptimalQuantity,NDC_Count)
		SELECT NDC,0,COUNT(NDC)
		FROM #Temp_OverSupply
		GROUP BY NDC
	
	 /*Update Optimume quantity*/
	 UPDATE #Temp_OverSupply_OQ
		SET OptimalQuantity = dbo.FN_calculate_optimum_qty(NDC,@pharmacy_id)
	
	 UPDATE temp_OS
		SET temp_OS.OptimalQuantity = temp_OSOQ.OptimalQuantity
	 FROM #Temp_OverSupply temp_OS
	 INNER JOIN #Temp_OverSupply_OQ temp_OSOQ ON temp_OSOQ.NDC = temp_OS.NDC	 		
	 
	 /*----------------------------------------------------*/

	--SELECT * FROM #Temp_OverSupply_OQ
	DROP TABLE #Temp_OverSupply_OQ
		  

	 
	
	
		
	SELECT  @count= IsNull (COUNT(*),0) FROM #Temp_OverSupply
	WHERE (
			
			((MedicineName LIKE '%'+ISNULL(@SearchString,MedicineName)+'%')
			 or (NDC LIKE '%'+ISNULL(@SearchString,NDC)+'%'))
			AND (ExpirtyDate > GETDATE()) AND (QuantityOnHand > (OptimalQuantity * 1.3))			
	)

     UPDATE #Temp_OverSupply SET Count=@count
	 
	 IF @PageSize > 0
	 BEGIN
	 SELECT * FROM #Temp_OverSupply 
	 WHERE (
			
			((MedicineName LIKE '%'+ISNULL(@SearchString,MedicineName)+'%')
			 or (NDC LIKE '%'+ISNULL(@SearchString,NDC)+'%'))
			AND (ExpirtyDate > GETDATE()) AND (QuantityOnHand > (OptimalQuantity * 1.3))			
	)
		 ORDER BY WholesalerId		
		 OFFSET  @PageSize * (@PageNumber - 1)   ROWS
        FETCH NEXT @PageSize ROWS ONLY
	END
	ELSE
	BEGIN
	 SELECT * FROM #Temp_OverSupply 
		 WHERE (
			
			((MedicineName LIKE '%'+ISNULL(@SearchString,MedicineName)+'%')
			 or (NDC LIKE '%'+ISNULL(@SearchString,NDC)+'%'))
			AND (ExpirtyDate > GETDATE()) AND (QuantityOnHand > (OptimalQuantity * 1.3))			
	)
		 ORDER BY WholesalerId		
	END	 
	
	-- RETURN @var1;



  END



  --select * from inventory where NDC = 169266015




GO
/****** Object:  StoredProcedure [dbo].[SP_OverSupply2]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
  
-- =============================================  
  
-- Create date: 27-03-2018  
  
-- Description: SP to show oversupply(forcasting) of medicines  
--EXEC SP_OverSupply2 12,0,1,''  
-- =============================================  
  
  
CREATE PROC [dbo].[SP_OverSupply2]  
  
  @pharmacy_id int,  
  @PageSize  int,  
  @PageNumber    int,    
  @SearchString  nvarchar(100)=null  
  
  AS  
  
   BEGIN  
  
    DECLARE @count int;    
  
 DECLARE @expired_month INT  
 SELECT @expired_month = [expiry_month] FROM [Inv_Exp_Config]  
   
 DECLARE @cdate DATETIME = DATEADD(month, -3, GETDATE())  
  
 ;WITH OverSupply AS (  
    SELECT    
    pharmacy_id       AS PharmacyId,  
    ISNULL(wholesaler_id,0)          AS WholesalerId,  
    drug_name        AS MedicineName,  
    ndc         AS NDC,  
    pack_size        AS QuantityOnHand,  
    opt         AS OptimalQuantity,  
    strength        AS Strength,  
    EOMONTH(DATEADD(month, @expired_month, ISNULL(created_on,GETDATE()))) AS ExpirtyDate,  
    inv.price         AS Price  
   FROM [dbo].[inventory] inv  
   CROSS APPLY (  
    SELECT SUM(qty_disp) / 3 AS opt  
    FROM [dbo].[RX30_inventory] rx   
    WHERE rx.ndc = inv.ndc AND rx.pharmacy_id = inv.pharmacy_id AND rx.created_on >= @cdate AND rx.is_deleted IS NULL  
   ) rx  
  
   WHERE   
   (pharmacy_id = @pharmacy_id) AND (ISNULL(is_deleted,0) = 0) AND (ISNULL(pack_size,0) > 0)  
 )  
 SELECT   
  PharmacyId,  
  WholesalerId,  
  MedicineName,  
  NDC,  
  QuantityOnHand,  
  OptimalQuantity,  
  ExpirtyDate,  
  Strength,  
  Price,  
  COUNT(1) OVER () AS Count  
 FROM OverSupply  
 WHERE ((MedicineName LIKE '%'+ISNULL(@SearchString,MedicineName)+'%')  
  OR (NDC LIKE '%'+ISNULL(@SearchString,NDC)+'%'))  
  AND (ExpirtyDate > GETDATE()) AND (QuantityOnHand > (OptimalQuantity * 1.3))     
 ORDER BY WholesalerId, MedicineName  
 OFFSET  @PageSize * (@PageNumber - 1)   ROWS  
 FETCH NEXT IIF(@PageSize = 0, 100000, @PageSize) ROWS ONLY  
  
  
  
  END  
  
  
  
  --select * from inventory where NDC = 169266015  
  
  
  
  
  
  

  
  
GO
/****** Object:  StoredProcedure [dbo].[SP_pharmacydashboard]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Create date: 10-05-2018
-- Description: SP to show pending order,current on
   -- hand,expired inventory,surplus inventory
  -- exec SP_pharmacydashboard 12
-- =============================================

CREATE PROC [dbo].[SP_pharmacydashboard]
	@pharmacy_id        INT
	
AS
BEGIN 
	DECLARE @Current_Date DATETIME = GETDATE();
	DECLARE	@pending_order      BIGINT=0;
	DECLARE @currentonhand      BIGINT=0;
	DECLARE @expired_inventory  BIGINT=0;
	DECLARE @surplus_inventory  BIGINT=0;

	DECLARE @expired_month INT
	SELECT @expired_month = [expiry_month] FROM [Inv_Exp_Config]

--------------------------pending order---------------------------
	--SELECT	@pending_order=SUM(CAST(ITM.remaining_quantity AS INT))
	--FROM [dbo].[invoice_additionalItem] AS ITM
	--INNER JOIN 
	--[dbo].[invoice_line_items] AS IT1
	--ON ITM.invoice_items_id = IT1.invoice_lineitem_id
	--INNER JOIN 
	--[dbo].[invoice] AS INV
	--ON IT1.invoice_id = INV.invoice_id
	--WHERE pharmacy_id = @pharmacy_id
	--AND (ISNULL(INV.is_deleted,0) = 0)  
select @pending_order = 
--(sum(cast(lineitem.QtyOrdered as int)) -  sum(cast(ack.QTY as int)))
count(ack.QTY) 
from invoice as inv
inner join [dbo].[invoice_line_items] itm 
on inv.[invoice_id] = itm.invoice_id
inner join [dbo].[invoice_additionalItem] remaining
on itm.[invoice_lineitem_id] = remaining.[invoice_items_id]
inner join [dbo].[Ack_BAK_PurchaseOrder] bak
on inv.[purchase_order_number] = bak.[PurchaseOrderNumber]
inner join [dbo].[Ack_LineItem] lineitem
on bak.BAK_ID = lineitem.[BAK_ID]
inner join [dbo].[Ack_LineItemACK] ack
on lineitem.[LineItem_ID] = ack.[LineItem_ID]
where inv.pharmacy_id = @pharmacy_id
AND (ISNULL(INV.is_deleted,0) = 0)
AND ack.[StatusCode] in ('IB','IR','IW','IQ')


--------------------------current on hand-------------------------
	SELECT @currentonhand=SUM(ISNULL(price,0 )* ISNULL(pack_size,0) ) FROM inventory
	 WHERE pharmacy_id=@pharmacy_id AND ISNULL(is_deleted,0)=0 AND ISNULL(pack_size,0)>0
	AND NOT EOMONTH(created_on , @expired_month) < @Current_Date
--------------------------expired inventory-----------------------

    --SELECT @expired_inventory=SUM(ISNULL(price,0 )* ISNULL(pack_size,0) ) FROM inventory 
    --WHERE pharmacy_id=@pharmacy_id AND ISNULL(is_deleted,0)=0 AND ISNULL(pack_size,0)>0
    --AND EOMONTH(created_on , @expired_month) < @Current_Date

	SELECT @expired_inventory=SUM(ISNULL(price,0 )* ISNULL(pack_size,0) ) FROM inventory
	WHERE  DATEADD(mm,+9,created_on) > GETDATE()
	AND DATEDIFF(mm,GETDATE(),DATEADD(mm,+9,created_on)) <= 3
	AND pharmacy_id = @pharmacy_id AND ISNULL(is_deleted,0)=0 AND ISNULL(pack_size,0)>0

--------------------------surplus inventory------------------------

	
	 CREATE TABLE #Temp_Remaining_Surplus_Inventory
			 (				
				  PharmacyId		INT,
				  WholesalerId		INT,
				  MedicineName		NVARCHAR(500),
				  NDC				BIGINT,
				  QuantityOnHand	DECIMAL(10,2),
				  OptimalQuantity	DECIMAL(10,2),
				  ExpirtyDate		DATETIME,
				  Price				DECIMAL(12,2),
				  Count				INT,	
				  Strength          NVARCHAR(1000)			 
			 )
	 
	 INSERT INTO #Temp_Remaining_Surplus_Inventory(PharmacyId, WholesalerId, MedicineName, NDC, QuantityOnHand, OptimalQuantity, ExpirtyDate,Strength, Price, Count)
	 EXEC SP_OverSupply @pharmacy_id,0,1,''
	 SELECT @surplus_inventory=SUM(ISNULL(Price,0 )* ISNULL(QuantityOnHand,0) ) from #Temp_Remaining_Surplus_Inventory
	-- Drop table #Temp_Remaining_Surplus_Inventory

--------------------------------------------------------------------
	  CREATE TABLE #Temp_dashboard
	  (
	  Pending_order   DECIMAL(20,2),
	  CurrentOnHand   DECIMAL(20,2),
	  Expired_inventory DECIMAL(20,2),
	  SurplusSummary	DECIMAL(20,2)
	  )

	  INSERT INTO #Temp_dashboard (Pending_order,CurrentOnHand,Expired_inventory,SurplusSummary) VALUES
	  (@pending_order,@currentonhand, @expired_inventory,@surplus_inventory)

	 SELECT * FROM #Temp_dashboard

--------------------------------------------------------------------

DROP TABLE #Temp_Remaining_Surplus_Inventory		
DROP TABLE #Temp_dashboard	


END

--EXEC SP_pharmacydashboard	24
--SELECT * from inventory
--update inventory set created_on ='2018-01-12 06:13:30.227' where inventory_id=205757












GO
/****** Object:  StoredProcedure [dbo].[SP_pharmacyList]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 06-20-2018
-- Description: SP to show pharmacy list with pagination and serarching
--SP_pharmacyList 10,1,''
-- =============================================

CREATE PROC [dbo].[SP_pharmacyList] 
  @PageSize		int,
  @PageNumber    int,
  @SearchString  nvarchar(100)=null

	AS
   BEGIN
   DECLARE @count int;
  
	SELECT
	 P.pharmacy_id,
	 P.pharmacy_name,
	 P.subscription_status,
	 U.first_name,U.last_name,
	 S.plan_name
	INTO #Temp_pharmacylist
	FROM 	
	pharmacy_list P join sa_pharmacy_owner U
	ON P.pharmacy_owner_id=U.pharmacy_owner_id
	JOIN sa_subscription_plan S
	ON
	P.subscription_plan_id=S.subscription_plan_id
	WHERE	
	 ((P.pharmacy_name LIKE '%'+ISNULL(@SearchString,P.pharmacy_name)+'%' OR ( S.plan_name LIKE '%'+ISNULL(@SearchString, S.plan_name)+'%'))
	 AND (P.is_deleted!= 1)
	 )
   
     -- UPDATE TABLE FOR SUBSCRIPTION STATUS
	  UPDATE #Temp_pharmacylist  
	 SET subscription_status = CASE
                  WHEN subscription_status = 1 THEN 'Active'
                  ELSE 'Deactive'
				  END

   -- COUNT RECORD
	 SELECT @count= COUNT(*) FROM #Temp_pharmacylist 

		 -- SELECT RECORD FROM TEMP TABLE
		 SELECT
		 pharmacy_id					  AS PharmacyId,
		 pharmacy_name					  AS PharmacyName,
		 subscription_status			  AS SubscriptionStatus,
		 first_name +' '+	last_name      AS Name,		
		 plan_name						  AS PlanName,
		 @count                           As Count
		 FROM #Temp_pharmacylist
		 ORDER BY pharmacy_id desc
		 OFFSET  @PageSize * (@PageNumber - 1)   ROWS
         FETCH NEXT @PageSize ROWS ONLY	

		 -- drop temporary table
		 DROP TABLE #Temp_pharmacylist
  END


  --SELECT * FROM PHARMACY_LIST
 -- SELECT * FROM [dbo].[sa_pharmacy_owner]



GO
/****** Object:  StoredProcedure [dbo].[SP_pricebreakanalyser]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:		<SAGAR>
-- Create date: <13-04-2018>
-- Description:	<SP to calculate the price break analyser for a particular ndc and plan related to that ndc.>
--SP_pricebreakanalyser 1417,430042014
-- =============================================
CREATE PROCEDURE [dbo].[SP_pricebreakanalyser]
	@pharmacyId   int,
	@ndc        bigint

AS
	BEGIN

		select  
		plan_name as PlanName, 
		(sum(plan_paid) + sum(pat_paid)) as PlanReimbursement,
		(select  (sum(plan_paid) + sum(pat_paid))  from Rx30_inventory where pharmacy_id =@pharmacyId AND ndc = @ndc group by ndc) AS TotalReimbursement

		from Rx30_inventory where pharmacy_id =@pharmacyId AND ndc = @ndc AND created_on>=DATEADD(month, -3, GETDATE()) group by  plan_name

/*
As per as alex he tell to modify the price break analyser and get reimbursement of drug for current 3 months only
*/
END



--select * from Rx30_inventory
--where generic_code !=null
-- where drug_name like '%RXLO LOESTRIN FE TAB 5X28%'

GO
/****** Object:  StoredProcedure [dbo].[SP_PurchaseOrders]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
    
-- =============================================            
            
-- Create date: 26-02-2019            
-- Created By: Humera Sheikh          
-- Description: SP to show Purchase Orders          
-- EXEC SP_PurchaseOrders 13,0,1,''            
-- =============================================            
            
                    
 CREATE PROC [dbo].[SP_PurchaseOrders]      
                 
   @pharmacy_id int,      
   @PageSize  int,        
   @PageNumber    int,          
   @SearchString  nvarchar(100)=null         
            
  AS            
            
   BEGIN             
          
   SELECT          
    ship.shippment_id AS ShipmentId,        
    ISNULL(ship.tracking_number,'') AS TrackNumber,           
    ISNULL(ship.seller_pharmacy_id,0) AS SellerPharmacyId,      
    ISNULL(ph.pharmacy_name,'') AS SellerPharmacyName,             
    ship.order_received AS OrderReceived,        
    ISNULL(shp_md.Name,'UPS') AS ShippingMethod,      
    ISNULL(totalcost,0) AS   TotalCost,      
    ISNULL(ship.shipping_cost,0) AS ShippingCost,      
    COUNT(1) OVER () AS Count       
              
   FROM [dbo].[shippment] ship      
   CROSS APPLY (        
    SELECT SUM(quantity *  unit_price) AS TotalCost        
    FROM [dbo].[shippmentdetails] shp_dt         
    WHERE shp_dt.shippment_id = ship.shippment_id       
   ) shp_dt      
   LEFT JOIN [dbo].[pharmacy_list] ph ON ph.pharmacy_id = ship.seller_pharmacy_id      
   LEFT JOIN [dbo].[shipping_methods] shp_md ON shp_md.shipping_method_id = ship.shipping_method_id      
   WHERE ((ship.purchaser_pharmacy_id = @pharmacy_id)   AND (ISNULL(ship.order_received,0) =0))       
   ORDER BY ShipmentId      
   OFFSET  @PageSize * (@PageNumber - 1)   ROWS        
   FETCH NEXT IIF(@PageSize = 0, 100000, @PageSize) ROWS ONLY        
           
  END 
GO
/****** Object:  StoredProcedure [dbo].[SP_PurchaseOrderShipmentDetails]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================          
          
-- Create date: 27-02-2019          
-- Created By: Humera Sheikh        
-- Description: SP to show Purchase Orders  Details     
-- EXEC SP_PurchaseOrderShipmentDetails 8          
-- =============================================          
          
                  
 CREATE PROC [dbo].[SP_PurchaseOrderShipmentDetails]    
               
   @shipment_id int    
          
  AS          
          
   BEGIN           
        
   SELECT        
    shippment_id AS shippingId,  
    ndc AS NDC,         
    quantity AS quantity,    
    unit_price AS unitPrice,           
    drug_name AS drugName,      
    lot_number AS lotNumber,    
    exipry_date AS   exipryDate            
   FROM [dbo].[shippmentdetails] ship_dt    
   WHERE ship_dt.shippment_id = @shipment_id    
    
         
  END      
GO
/****** Object:  StoredProcedure [dbo].[SP_readbroadcast_notification]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author: Sagar Sharma     
-- Create date: 25-05-2018
-- Description: SP mark notification as read.
-- =============================================

CREATE PROC [dbo].[SP_readbroadcast_notification]
	@notificationId			INT

	AS
   BEGIN
		 UPDATE broadcast_notification 
		 SET
			is_read = 1 
			WHERE broadcast_notification_id = @notificationId
  END


GO
/****** Object:  StoredProcedure [dbo].[SP_recentLiquidation]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Create date: 11-04-2018
-- Description: SP to show recent liquidation list with pagination and serarching(Returns)
-- exec SP_recentLiquidation 1417,100,1,'FENTANYL '
-- =============================================

CREATE PROC [dbo].[SP_recentLiquidation]
  @pharmacy_id  int,
  @PageSize		int,
  @PageNumber    int,
  @SearchString  nvarchar(100)=null

	AS
   BEGIN
   DECLARE @count int;
     SELECT @count=COUNT(*) FROM inventory where pharmacy_id = @pharmacy_id AND (drug_name LIKE '%'+ISNULL(@SearchString,drug_name)+'%' OR
		 ndc LIKE '%'+ISNULL(@SearchString,ndc)+'%')

  	SELECT
	     inventory_id					  AS ReturnId,
		 pharmacy_id					  AS PharmacyId,
		 ISNULL(wholesaler_id,0)          AS WholesalerId,
		 drug_name						  AS MedicineName,
		 pack_size						  AS Quantity,
		 price						      AS Value	,
		 @count                           As Count
		        
		 FROM [dbo].[inventory] 
		 WHERE 	pharmacy_id = @pharmacy_id AND (drug_name LIKE '%'+ISNULL(@SearchString,drug_name)+'%' OR
		 ndc LIKE '%'+ISNULL(@SearchString,ndc)+'%')
		 ORDER BY inventory_id desc
		 OFFSET  @PageSize * (@PageNumber - 1)   ROWS
         FETCH NEXT @PageSize ROWS ONLY	

  END




GO
/****** Object:  StoredProcedure [dbo].[SP_RecommendedForReturn_rawdata]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
    
-- =============================================        
-- Author:      Priyanka Chandak        
-- Create date: 10-04-2018     
-- Updated date: 04-03-2019   
-- Description: SP to show surplus Summary returns        
-- SP_RecommendedForReturn_rawdata 13        
-- =============================================        
 CREATE PROC [dbo].[SP_RecommendedForReturn_rawdata]        
        
  @pharmacy_id INT        
            
 AS        
                  
 BEGIN          
  DECLARE @loc_pharmacy_id INT
  SET @loc_pharmacy_id = @pharmacy_id
             
 DECLARE @expired_month INT        
 DECLARE @cdate DATETIME = DATEADD(month, -3, GETDATE())        
 SELECT @expired_month = [expiry_month] FROM [Inv_Exp_Config]        
      
 ;WITH RecommendedForReturn AS (      
   SELECT      
        
  inv.inventory_id      AS inventory_id,            
  inv.pharmacy_id      AS pharmacy_id,        
  inv.wholesaler_id      AS wholesaler_id,         
  inv.drug_name       AS drug_name,          
  inv.ndc        AS ndc,           
  inv.pack_size       AS QuantityOnHand,        
  ROUND(opt,0)         AS OptimalQuantity,        
  --dbo.FN_calculate_optimum_qty(ndc,@pharmacy_id) AS OptimalQuantity,           
  inv.price        AS Price,        
  EOMONTH(DATEADD(month, @expired_month ,inv.created_on)) AS expiration_date,         
  inv.[opened]       AS opened,        
  inv.[damaged]       AS damaged,        
  inv.[non_c2]       AS non_c2,        
  inv.[created_on]   AS  created_on      
  FROM [dbo].[inventory] inv        
  CROSS APPLY (        
   SELECT SUM(qty_disp) / 3 AS opt        
   FROM [dbo].[RX30_inventory] rx         
   WHERE rx.ndc = inv.ndc AND rx.pharmacy_id = @loc_pharmacy_id AND rx.created_on >= @cdate AND rx.is_deleted IS NULL        
     ) rx         
  WHERE  (        
     (inv.pharmacy_id = @loc_pharmacy_id ) AND         
      (ISNULL(inv.is_deleted,0) = 0) AND         
      (ISNULL(inv.pack_size,0) > 0)            
     )       
   )            
  
  SELECT      
   inventory_id ,        
   pharmacy_id  ,          
   wholesaler_id ,          
   drug_name  ,          
   ndc    ,         
   QuantityOnHand ,        
   OptimalQuantity ,          
   price   ,        
   expiration_date ,        
   [opened]  ,        
   [damaged]  ,        
   [non_c2]  ,        
   [created_on]        
  FROM  RecommendedForReturn RR  
  WHERE ((ISNULL(RR.OptimalQuantity,0) > 0)  
  AND   
  (ISNULL(RR.QuantityOnHand,0) >= ISNULL(RR.OptimalQuantity,0) )   
    
 )       
                   
  END        
        
        
        
        
        
          
        


GO
/****** Object:  StoredProcedure [dbo].[SP_RecommendedForReturn_rawdata_backup_04_03_2019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 10-04-2018
-- Description: SP to show surplus Summary returns
--SP_RecommendedForReturn_rawdata 1417
-- =============================================
CREATE PROC [dbo].[SP_RecommendedForReturn_rawdata_backup_04_03_2019]

  @pharmacy_id INT
    
	AS
   BEGIN  
   
	DECLARE @expired_month INT
	SELECT @expired_month = [expiry_month] FROM [Inv_Exp_Config]
	  
   CREATE TABLE #Temp_RecommendedForReturn(		
		inventory_id	INT,
		pharmacy_id		INT,		
		wholesaler_id	INT,		
		drug_name		NVARCHAR(1000),		
		ndc				BIGINT,	
		QuantityOnHand	DECIMAL(10,2),
		OptimalQuantity DECIMAL(10,2),		
		price			MONEY,
		expiration_date	DATETIME,
		[opened]		BIT,
		[damaged]		BIT,
		[non_c2]		BIT,
		[created_on]	DATETIME
	)
	
	
	INSERT INTO  #Temp_RecommendedForReturn(inventory_id, pharmacy_id, wholesaler_id, drug_name, ndc, QuantityOnHand,OptimalQuantity,price,expiration_date,opened, damaged,non_c2,created_on )
  		SELECT		
			 inv.inventory_id						AS inventory_id,			 
			 inv.pharmacy_id						AS pharmacy_id,
			 inv.wholesaler_id						AS wholesaler_id,	
			 inv.drug_name							AS drug_name,		
			 inv.ndc								AS ndc,			
			 inv.pack_size							AS QuantityOnHand,
			 0										AS OptimalQuantity,
			 --dbo.FN_calculate_optimum_qty(ndc,@pharmacy_id)	AS OptimalQuantity,		 
			 inv.price								AS Price,
			 EOMONTH(DATEADD(month, @expired_month ,inv.created_on)), 
			 inv.[opened]							AS opened,
			 inv.[damaged]							AS damaged,
			 inv.[non_c2]							AS non_c2,
			 inv.[created_on]		
		 FROM [dbo].[inventory] inv

		 WHERE 	(
			(inv.pharmacy_id = @pharmacy_id ) AND 
			(ISNULL(inv.is_deleted,0) = 0) AND 
			(ISNULL(inv.pack_size,0) > 0) 			
		 )

		 		
	/*This logic added to avoid calculating Optimum quantity for duplicate ndc*/
	 CREATE TABLE #Temp_OQ(				
		NDC				BIGINT,		
		OptimalQuantity DECIMAL(10,2),
		NDC_Count       INT		
	)

	INSERT INTO #Temp_OQ(NDC,OptimalQuantity,NDC_Count)
		SELECT NDC,0,COUNT(NDC)
		FROM #Temp_RecommendedForReturn
		GROUP BY ndc
	
	 /*Update Optimume quantity*/
	 UPDATE #Temp_OQ
		SET OptimalQuantity = dbo.FN_calculate_optimum_qty(NDC,@pharmacy_id)
	
	 UPDATE temp_RFRS
		SET temp_RFRS.OptimalQuantity = temp_OQ.OptimalQuantity
	 FROM #Temp_RecommendedForReturn temp_RFRS
	 INNER JOIN #Temp_OQ temp_OQ ON temp_OQ.NDC = temp_RFRS.ndc	 		
	 

	 DROP TABLE #Temp_OQ	
	 /*----------------------------------------------------*/
		 	 		
	

	DELETE FROM #Temp_RecommendedForReturn WHERE ISNULL(OptimalQuantity,0) = 0
	DELETE FROM #Temp_RecommendedForReturn WHERE ISNULL(QuantityOnHand,0) < ISNULL(OptimalQuantity,0)
	
	SELECT * FROM #Temp_RecommendedForReturn
	DROP TABLE #Temp_RecommendedForReturn
	
  END





  





GO
/****** Object:  StoredProcedure [dbo].[SP_RecommendedForReturn_rawdata_bk_06102019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
    
-- =============================================        
-- Author:      Priyanka Chandak        
-- Create date: 10-04-2018     
-- Updated date: 04-03-2019   
-- Description: SP to show surplus Summary returns        
-- SP_RecommendedForReturn_rawdata 13        
-- =============================================        
 CREATE PROC [dbo].[SP_RecommendedForReturn_rawdata_bk_06102019]        
        
  @pharmacy_id INT        
            
 AS        
                  
 BEGIN          
           
 DECLARE @expired_month INT        
 DECLARE @cdate DATETIME = DATEADD(month, -3, GETDATE())        
 SELECT @expired_month = [expiry_month] FROM [Inv_Exp_Config]        
      
 ;WITH RecommendedForReturn AS (      
   SELECT      
        
  inv.inventory_id      AS inventory_id,            
  inv.pharmacy_id      AS pharmacy_id,        
  inv.wholesaler_id      AS wholesaler_id,         
  inv.drug_name       AS drug_name,          
  inv.ndc        AS ndc,           
  inv.pack_size       AS QuantityOnHand,        
  ROUND(opt,0)         AS OptimalQuantity,        
  --dbo.FN_calculate_optimum_qty(ndc,@pharmacy_id) AS OptimalQuantity,           
  inv.price        AS Price,        
  EOMONTH(DATEADD(month, @expired_month ,inv.created_on)) AS expiration_date,         
  inv.[opened]       AS opened,        
  inv.[damaged]       AS damaged,        
  inv.[non_c2]       AS non_c2,        
  inv.[created_on]   AS  created_on      
  FROM [dbo].[inventory] inv        
  CROSS APPLY (        
   SELECT SUM(qty_disp) / 3 AS opt        
   FROM [dbo].[RX30_inventory] rx         
   WHERE rx.ndc = inv.ndc AND rx.pharmacy_id = inv.pharmacy_id AND rx.created_on >= @cdate AND rx.is_deleted IS NULL        
     ) rx         
  WHERE  (        
     (inv.pharmacy_id = @pharmacy_id ) AND         
      (ISNULL(inv.is_deleted,0) = 0) AND         
      (ISNULL(inv.pack_size,0) > 0)            
     )       
   )            
  
  SELECT      
   inventory_id ,        
   pharmacy_id  ,          
   wholesaler_id ,          
   drug_name  ,          
   ndc    ,         
   QuantityOnHand ,        
   OptimalQuantity ,          
   price   ,        
   expiration_date ,        
   [opened]  ,        
   [damaged]  ,        
   [non_c2]  ,        
   [created_on]        
  FROM  RecommendedForReturn RR  
  WHERE ((ISNULL(RR.OptimalQuantity,0) > 0)  
  AND   
  (ISNULL(RR.QuantityOnHand,0) >= ISNULL(RR.OptimalQuantity,0) )   
    
 )       
                   
  END        
        
        
        
        
        
          
        


GO
/****** Object:  StoredProcedure [dbo].[SP_recommendedReturnTOwholesalerAmount]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Sagar Sharma
-- Modified By: Priyanka Chandak(12/4/2018) for server side pagination show extra fields
-- Create date: 06-04-2018
-- Description: SP to show the list of inventory for Recommended Return to wholesaler amount.
--EXEC SP_recommendedReturnTOwholesalerAmount 12,10,1,''
-- =============================================

CREATE PROC [dbo].[SP_recommendedReturnTOwholesalerAmount]
  @pharmacy_id int,
   @PageSize		int,
  @PageNumber    int,
  @SearchString  nvarchar(100)=null
	AS
   BEGIN
  	DECLARE @pastDate DATETIME ;
	DECLARE @count INT;
	SET @pastDate = DATEADD(month, -3, GETDATE());

	DECLARE @expired_month INT
	SELECT @expired_month = [expiry_month] FROM [Inv_Exp_Config]

	--DROP TABLE #Temp_recommendedReturnTOwholesalerAmount

	CREATE TABLE #Temp_recommendedReturnTOwholesalerAmount(
		MedicineName NVARCHAR(1000),
		NdcCode				BIGINT,
		WholesalerName NVARCHAR(100),
		Quantity   DECIMAL(10,2),
		WholesalerId  INT,
		PharmacyId   INT,
		InventoryId   INT,
		Amount    DECIMAL(10,3),
		ExpiryDate  DATETIME,
		Usages    NVARCHAR(50),
		Count     INT,
		LotNo	NVARCHAR(100),
		Strength  NVARCHAR(100)
	)
	/*
    recommended for transfer
    Must be greater than 6 month expiration dating
	Must be unopened and Undamaged item
	Must be a product carried by wholesaler (a non-discontinued item) 
	Non-C2 (narcotic controlled substance) inventory item.

   */

	INSERT INTO #Temp_recommendedReturnTOwholesalerAmount (MedicineName, NdcCode, WholesalerName,Quantity,WholesalerId,PharmacyId,InventoryId
	,Amount,ExpiryDate,Usages,LotNo,Strength)
	SELECT			
		 inv.drug_name		AS MedicineName,
		 inv.ndc			AS NdcCode,
		 w.name				AS WholesalerName,
		 inv.pack_size		AS Quantity,
		 inv.wholesaler_id	AS WholesalerId,
		 inv.pharmacy_id    AS PharmacyId,
		 inv.Inventory_id   AS InventoryId,
		 (inv.pack_size * inv.price) AS Amount,
		 EOMONTH(DATEADD(month, @expired_month, ISNULL(inv.created_on, GETDATE()))) AS ExpiryDate,
		 (CASE 
         WHEN inv.created_on < @pastDate OR inv.updated_on < @pastDate
		 THEN 'RED'
         ELSE 'GREEN' End)
		 AS Usages,
		 ''	 AS LotNo,
		 inv.strength  AS Strength
	 FROM inventory  inv
	-- INNER JOIN RX30_inventory inv_rx30 ON inv_rx30.[ndc] = inv.[ndc]
	 LEFT JOIN wholesaler w ON w.wholesaler_id = inv.wholesaler_id 
	 WHERE( 
			(inv.pharmacy_id = @pharmacy_id) AND
			(ISNULL(inv.is_deleted,0) = 0) AND 
			(ISNULL(inv.pack_size,0) > 0) AND

			(ISNULL(inv.opened,0) = 0) AND
			(ISNULL(inv.damaged,0) = 0) AND
			(ISNULL(inv.non_c2,0) = 0) AND		
			(GETDATE() > EOMONTH(DATEADD(month, @expired_month + 6, ISNULL(inv.created_on, GETDATE())))) /*adding the expiry date + 6 months*/				
			-- AND 
			--(inv_rx30.created_on > DATEADD(MONTH, -3, GETDATE()) ) /*Must be a product carried by wholesaler (a non-discontinued item) */ 	
				/*Note: Sagar/Prashant, it can not be the case the product is expiring and also continewing coming
				*/
		)
  
    
	SELECT @count=(ISNULL(count(*),0)) from #Temp_recommendedReturnTOwholesalerAmount
   
    UPDATE #Temp_recommendedReturnTOwholesalerAmount SET  Count=@count 

     SELECT * FROM #Temp_recommendedReturnTOwholesalerAmount
     WHERE (MedicineName LIKE '%'+ISNULL(@SearchString,MedicineName)+'%' OR
		 WholesalerName LIKE '%'+ISNULL(@SearchString,WholesalerName)+'%')
		 ORDER BY InventoryId
		 OFFSET  @PageSize * (@PageNumber - 1)   ROWS
         FETCH NEXT @PageSize ROWS ONLY	

  END



GO
/****** Object:  StoredProcedure [dbo].[SP_recommendedtransfer]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Sagar Sharma
-- Create date: 06-04-2018
-- Description: SP to show the list of inventory for recommended transfer.
-- EXEC SP_recommendedtransfer 1417
-- =============================================

CREATE PROC [dbo].[SP_recommendedtransfer]
  @pharmacy_id int
	AS
   BEGIN
  	
	CREATE TABLE #Temp_RecommendedForReturn(		
		inventory_id	INT,
		pharmacy_id		INT,		
		wholesaler_id	INT,		
		drug_name		NVARCHAR(1000),		
		ndc				BIGINT,		
		QuantityOnHand	DECIMAL(10,2),
		OptimalQuantity DECIMAL(10,2),		
		price			MONEY,
		expiration_date	DATETIME,
		[opened]		BIT,
		[damaged]		BIT,
		[non_c2]		BIT,
		[created_on]	DATETIME
	)
	
	
	INSERT INTO  #Temp_RecommendedForReturn(inventory_id,pharmacy_id,wholesaler_id,drug_name,ndc,QuantityOnHand,OptimalQuantity,price,expiration_date,opened, damaged,non_c2,created_on )
  		EXEC SP_RecommendedForReturn_rawdata @pharmacy_id
		
		 	 		

	SELECT
		 --inv_rx30.drug_name							AS MedicineName,
		 temp_RFR.drug_name							AS MedicineName,
		 temp_RFR.ndc								AS NdcCode,
		 temp_RFR.QuantityOnHand					AS Quantity,
		 (temp_RFR.QuantityOnHand * temp_RFR.price) AS Amount,
		 temp_RFR.expiration_date					AS ExpiryDate
	 FROM #Temp_RecommendedForReturn temp_RFR
	 --INNER JOIN RX30_inventory inv_rx30 ON inv_rx30.[ndc] = temp_RFR.[ndc] 
		WHERE (
				( GETDATE() > DATEADD(month, 6 ,temp_RFR.expiration_date) ) AND /*Must be greater than 6 month expiration dating*/
				(ISNULL(temp_RFR.opened,0) = 0) AND
				(ISNULL(temp_RFR.damaged,0) = 0) AND
				(ISNULL(temp_RFR.non_c2,0) = 0) /*AND
				(inv_rx30.created_on > DATEADD(MONTH, -3, GETDATE()) ) /*Must be a product carried by wholesaler (a non-discontinued item) */
				*/
				/*Note: Sagar/Prashant, it can not be the case the product is expiring and also continewing coming
				*/
			)
			
		
		DROP TABLE #Temp_RecommendedForReturn			

  END

 

GO
/****** Object:  StoredProcedure [dbo].[SP_Reimburement]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================

-- Author:		<Priyanka>

-- Create date: <06-05-2018>

-- Description:	<SP to calculate the reimburesement for a particular generic code >

--SP_Reimburement_backup 1417,430042014



--SP_Reimburement 1417,430042014

--SP_Reimburement 1417, 68001011306

-- =============================================



CREATE PROC [dbo].[SP_Reimburement]

(

@pharmacyId		INT,

@ndc			BIGINT

)



AS 

BEGIN

 --drop table #Temp_genericdata

		SELECT I.ndc,R.generic_code AS GenericCode INTO #Temp_genericdata

		FROM inventory I JOIN rx30_inventory R

		ON I.ndc=R.ndc

		WHERE  ((I.pharmacy_id =@pharmacyId )

		AND  (I.ndc =@ndc) 

		AND (R.plan_name != '') AND (R.plan_paid>0) )



		SELECT 

	    R.plan_name AS PlanName, 

	   ((ISNULL(SUM(R.plan_paid),0) + ISNULL(SUM(R.pat_paid),0)))/(ISNULL(SUM(R.qty_disp),1)) AS PlanReimbursement

	  

	   INTO #Temp_Reimburement

	   FROM Rx30_inventory R JOIN #Temp_genericdata G

	   ON R.generic_code=G.GenericCode

	   WHERE ((R.pharmacy_id =@pharmacyId) AND (R.ndc = @ndc) and (R.plan_paid>0)

	  )

	   

	    GROUP BY  R.plan_name



	    SELECT ((ISNULL(SUM(plan_paid),0) + ISNULL(SUM(pat_paid),0)))/(ISNULL(SUM(qty_disp),1)) AS PlanPaid,  plan_name AS PlanName

		INTO #Temp_avg

		FROM Rx30_inventory 

		WHERE (( ndc=@ndc) AND (pharmacy_id=@pharmacyId) AND (plan_paid > 0) )

        GROUP BY plan_name



	

		--DECLARE @max					DECIMAL(18,2)

		DECLARE @avg					DECIMAL(18,2)

		DECLARE @TotalReimbursement     DECIMAL(18,2)

		SELECT @avg=((SUM(PlanPaid))/(ISNULL(COUNT(*),1)) )  FROM #Temp_avg 

		--SELECT @max =(MAX(PlanPaid))  FROM #Temp_avg 

		SELECT @TotalReimbursement =(ISNULL(SUM(PlanReimbursement),0)) FROM #Temp_Reimburement



	   SELECT

	   PlanName											 AS PlanName,

	   (ISNULL((PlanReimbursement),0))                   AS PlanReimbursement,

	  (ISNULL((@TotalReimbursement),0))				 AS TotalReimbursement,

	   (ISNULL((@avg),0))								 AS AverageReimbursement

	   --(ISNULL((@max),0))								 AS RecommendedNDC

	   FROM #Temp_Reimburement







END



SELECT DISTINCT
       o.name AS Object_Name,
       o.type_desc
  FROM sys.sql_modules m
       INNER JOIN
       sys.objects o
         ON m.object_id = o.object_id
 WHERE m.definition Like 'tertiary';

--SELECT * FROM RX30_INVENTORY WHERE NDC=68001011306


GO
/****** Object:  StoredProcedure [dbo].[SP_Reimburement_backup]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:		<Priyanka>
-- Create date: <06-05-2018>
-- Description:	<SP to calculate the reimburesement for a particular generic code >
--SP_Reimburement_backup 1417,430042014

--SP_Reimburement 1417,430042014
--SP_Reimburement 1417, 68001011306
-- =============================================

CREATE PROC [dbo].[SP_Reimburement_backup]
(
@pharmacyId		INT,
@ndc			BIGINT
)

AS 
BEGIN
 --drop table #Temp_genericdata
		SELECT I.ndc,R.generic_code AS GenericCode INTO #Temp_genericdata
		FROM inventory I JOIN rx30_inventory R
		ON I.ndc=R.ndc
		WHERE  ((I.pharmacy_id =@pharmacyId )
		AND  (I.ndc =@ndc) 
		AND (R.plan_name != '') AND (R.plan_paid>0) )

		SELECT 
	    R.plan_name AS PlanName, 
	   ((ISNULL(SUM(R.plan_paid),0) + ISNULL(SUM(R.pat_paid),0)))/(ISNULL(SUM(R.qty_disp),1)) AS PlanReimbursement
	  
	   INTO #Temp_Reimburement
	   FROM Rx30_inventory R JOIN #Temp_genericdata G
	   ON R.generic_code=G.GenericCode
	   WHERE ((R.pharmacy_id =@pharmacyId) AND (R.ndc = @ndc) and (R.plan_paid>0)
	  )
	   
	    GROUP BY  R.plan_name

	    SELECT ((ISNULL(SUM(plan_paid),0) + ISNULL(SUM(pat_paid),0)))/(ISNULL(SUM(qty_disp),1)) AS PlanPaid,  plan_name AS PlanName
		INTO #Temp_avg
		FROM Rx30_inventory 
		WHERE (( ndc=@ndc) AND (pharmacy_id=@pharmacyId) AND (plan_paid > 0) )
        GROUP BY plan_name

	
		--DECLARE @max					DECIMAL(18,2)
		DECLARE @avg					DECIMAL(18,2)
		DECLARE @TotalReimbursement     DECIMAL(18,2)
		SELECT @avg=((SUM(PlanPaid))/(ISNULL(COUNT(*),1)) )  FROM #Temp_avg 
		--SELECT @max =(MAX(PlanPaid))  FROM #Temp_avg 
		SELECT @TotalReimbursement =(ISNULL(SUM(PlanReimbursement),0)) FROM #Temp_Reimburement

	   SELECT
	   PlanName											 AS PlanName,
	   (ISNULL((PlanReimbursement),0))                   AS PlanReimbursement,
	   (ISNULL((@TotalReimbursement),0))				 AS TotalReimbursement,
	   (ISNULL((@avg),0))								 AS AverageReimbursement
	   --(ISNULL((@max),0))								 AS RecommendedNDC
	   FROM #Temp_Reimburement



END


--SELECT * FROM RX30_INVENTORY WHERE NDC=68001011306


GO
/****** Object:  StoredProcedure [dbo].[SP_reportList]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 23-04-2018
-- Description: SP to show report list with pagination and serarching
-- SP_reportList 1417,200,1,''
-- =============================================

CREATE PROC [dbo].[SP_reportList]
  @pharmacy_id  int,
  @PageSize		int,
  @PageNumber    int,
  @SearchString  nvarchar(100)=null

	AS
   BEGIN
   DECLARE @count int;

	 CREATE TABLE #Temp_reportList
	 (
	 InventoryId    INT,
	 PharmacyId     INT,
	 WholesalerId   INT,
	 DrugName       NVARCHAR(500),
	 DrugIdentifier BIGINT,
	 ExpiryDate     DATETIME,
	 GenericCode	BIGINT,
	 UnitsInHand    DECIMAL(20,2),
	 UnitCost	    DECIMAL(20,2),
	 ExtendedQuantity DECIMAL(20,2),
	 Count			INT,
	 Strength		NVARCHAR(100)
	 )
	 INSERT INTO #Temp_reportList(InventoryId,PharmacyId,WholesalerId,DrugName,DrugIdentifier,ExpiryDate,GenericCode,UnitsInHand,UnitCost,ExtendedQuantity,Strength)
  	SELECT
	     inventory_id					  AS InventoryId,
		 pharmacy_id					  AS PharmacyId,
		 ISNULL(wholesaler_id,0)          AS WholesalerId,
		 drug_name						  AS DrugName,
		 ndc							  AS DrugIdentifier,
		 EOMONTH(DATEADD(mm,+9,created_on)) AS ExpiryDate,
		 generic_code					  AS GenericCode,
		 pack_size						  AS UnitsInHand,
		 price						      AS UnitCost	,
		 (pack_size * price)	  AS ExtendedQuantity,
		 strength					AS Strength
		 FROM [dbo].[inventory] 
		 WHERE 	pharmacy_id = @pharmacy_id AND pack_size>0 AND is_deleted=0 AND (drug_name LIKE '%'+ISNULL(@SearchString,drug_name)+'%' OR
		 ndc LIKE '%'+ISNULL(@SearchString,ndc)+'%' ) 
		      
	     SELECT @count=ISNULL(COUNT(*),0) FROM #Temp_reportList
		 UPDATE #Temp_reportList SET Count=@count

	

		 
	 IF @PageSize > 0
	 BEGIN
		 SELECT * FROM #Temp_reportList
		 ORDER BY InventoryId desc
		 OFFSET  @PageSize * (@PageNumber - 1)   ROWS
         FETCH NEXT @PageSize ROWS ONLY	


	END
	ELSE
	BEGIN
	 SELECT * FROM #Temp_reportList
		 ORDER BY InventoryId desc
		
	END	 
	

  END


  --select * from inventory

 -- EXEC SP_reportList 1,10,1,''



GO
/****** Object:  StoredProcedure [dbo].[SP_returnalert_summarylist]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 17-04-2018
-- Description: SP to show return alert summary list with pagination and serarching
-- =============================================
--  SP_returnalert_summarylist 1, 10, 1, '','4/20/2018'
CREATE PROC [dbo].[SP_returnalert_summarylist]
  @pharmacy_id  int,
  @PageSize		int,
  @PageNumber    int,
  @SearchString  nvarchar(100)=null,
  @alertdate	 DATETIME

	AS
   BEGIN
   DECLARE @count int;  
  	 SELECT @count=COUNT(*) FROM returnalert where FORMAT(alert_date,'MM/dd/yyyy') = FORMAT(GETDATE(),'MM/dd/yyyy')
	 AND pharmacy_id=@pharmacy_id
	 
	 SELECT 
	 R.alert_date  AS AlertDate,
	isnull(I.drug_name,'')   AS DrugName,
	 isnull(I.ndc,0)		   AS NDC,
	 isnull(I.pack_size,0)   AS Quantity,
	 isnull(I.price,0)	   AS Price,
	 @count		   AS Count	 
	 FROM [dbo].[returnalert] R left join inventory I ON R.wholesalerId=I.wholesaler_id AND R.ndc=I.ndc
	 WHERE R.pharmacy_id=I.pharmacy_id  
	 AND FORMAT(R.alert_date,'MM/dd/yyyy') = FORMAT(@alertdate,'MM/dd/yyyy')
	 AND	(I.drug_name LIKE '%'+ISNULL(@SearchString,I.drug_name)+'%')
	 ORDER BY R.alert_Id desc
	 OFFSET  @PageSize * (@PageNumber - 1)   ROWS
     FETCH NEXT @PageSize ROWS ONLY	   	


  END

  --exec SP_returnalert_summarylist 1,10,1,'','2018-04-20 09:51:18.563'
 --select * from returnalert



GO
/****** Object:  StoredProcedure [dbo].[SP_returnalert_summarylist1]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Create date: 17-04-2018
-- Description: SP to show return alert summary list with pagination and serarching
-- EXEC SP_returnalert_summarylist1 12,10,1,''
-- =============================================

CREATE PROC [dbo].[SP_returnalert_summarylist1]
  @pharmacy_id  int,
  @PageSize		int,
  @PageNumber    int,
  @SearchString  nvarchar(100)=null
 
	AS
   BEGIN
   DECLARE @count int=0;   
	 CREATE TABLE #Temp_returnalert
	 (
	 AlertId     INT,
	 AlertDate  DATETIME,
	 DrugName   NVARCHAR(1000),
	 Description NVARCHAR(2000),	
	 Quantity   DECIMAL(18,2),
	 Price      DECIMAL(18,2),
	  Count      INT,
	  WholesalerId  INT
	
	 )
	
	 INSERT INTO #Temp_returnalert
	 SELECT 
	 R.alert_id    AS	  AlertId,
	 R.alert_date  AS	  AlertDate,
	 I.drug_name   AS	  DrugName,
	 R.description AS	  Description,
	 I.pack_size   AS	  Quantity,
	 I.price	   AS	  Price
	 ,COUNT(1) OVER () AS Count,
	 I.wholesaler_id   AS WholesalerId	 
	 FROM [dbo].[returnalert] R JOIN inventory I ON R.drug_InventoryId=I.inventory_id
	 WHERE 	
	 (R.pharmacy_id=@pharmacy_id)
	 AND (I.drug_name LIKE '%'+ISNULL(@SearchString,I.drug_name)+'%')
	
	  
	 SELECT @count=(ISNULL(COUNT(*),0)) from #Temp_returnalert	 

	 update #Temp_returnalert set Count=@count 
	 select 
	 AlertDate,	 DrugName,	 Description,	 Quantity,	 Price,	 Count,	 WholesalerId	
	 from #Temp_returnalert
	 ORDER BY AlertId desc 
	 OFFSET  @PageSize * (@PageNumber - 1)   ROWS    
     FETCH NEXT IIF(@PageSize = 0, 100000, @PageSize) ROWS ONLY     

  END




 --select * from returnalert




GO
/****** Object:  StoredProcedure [dbo].[SP_ReturnAlertNotificatioon]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Create date: 28-05-2018
-- Description: SP to show return alert summary list notification
-- EXEC SP_ReturnAlertNotificatioon 1417,100,1,''
-- =============================================

CREATE PROC [dbo].[SP_ReturnAlertNotificatioon]
  @pharmacy_id  INT,
  @pageSize		INT,
  @pageNumber   INT,
  @searchString	NVARCHAR(100)=NULL

  AS
  BEGIN

    DECLARE @count int=0; 
	DECLARE @newcount  int=0;  
	
	SELECT @newcount=(ISNULL(COUNT(*),0)) FROM returnalert 
	WHERE (
	(is_read=0) AND
	(FORMAT(alert_date,'MM/dd/yyyy') <= FORMAT(GETDATE(),'MM/dd/yyyy')) AND
	(pharmacy_id=@pharmacy_id) 
	)

	 SELECT 
	 R.alert_Id		 AS AlertId,
	 R.alert_date    AS AlertDate,
	 I.drug_name     AS DrugName,
	 R.description   AS Description,
	 I.pack_size     AS Quantity,
	 I.price	     AS Price
	 ,@count		 AS Count,
	 @newcount		 AS TotalCount,
	 I.wholesaler_id AS WholesalerId,
	 W.name          AS WholesalerName	 
	 INTO #Temp_returnalert
	 FROM [dbo].[returnalert] R JOIN inventory I ON R.drug_InventoryId=I.inventory_id
	 JOIN [dbo].[wholesaler] W ON I.wholesaler_id=W.wholesaler_id
	 WHERE (	
			(FORMAT(R.alert_date,'MM/dd/yyyy') <= FORMAT(GETDATE(),'MM/dd/yyyy')) AND
	        (R.pharmacy_id=@pharmacy_id) AND 
			(I.drug_name LIKE '%'+ISNULL(@searchString,I.drug_name)+'%')
			)
	
	 SELECT @count=(ISNULL(COUNT(*),0)) from #Temp_returnalert	 

	 update #Temp_returnalert set Count=@count 
	 select * from #Temp_returnalert
	 ORDER BY Quantity 
	 OFFSET  @pageSize * (@pageNumber - 1)   ROWS
     FETCH NEXT @pageSize ROWS ONLY	

  END

  --select * from returnalert

GO
/****** Object:  StoredProcedure [dbo].[SP_returnToWholesaler]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 06-04-2018
-- Description: SP to show Return to wholesaler list with pagination and searching
-- =============================================


CREATE PROC [dbo].[SP_returnToWholesaler]
  @pharmacy_id  int,
  @PageSize		int,
  @PageNumber    int,
  @SearchString  nvarchar(100)=null

	AS
   BEGIN

   CREATE TABLE #Temp_wholesalerreturn
   (
   ReturnToWholesaler  BIGINT,
   InventoryId		   BIGINT
  
   )

       INSERT INTO #Temp_wholesalerreturn
	   SELECT A.returntowholesaler_Id AS ReturnToWholesaler,B.inventory_id as InventoryId  FROM ReturnToWholesaler A join return_to_wholesaler_items B on
	   A.returntowholesaler_Id= B.returntowholesaler_Id
	   WHERE B.is_deleted !=1

	   DECLARE @count int;
       SELECT @count=COUNT(*) FROM #Temp_wholesalerreturn;
	   

	   SELECT I.inventory_id  AS InventoryId,
	   I.pharmacy_id          AS PharmacyId,
	   I.wholesaler_id		  AS WholesalerId,
	   I.drug_name			  AS DrugName,
	   I.ndc				  AS NDC,
	   I.pack_size			  AS Quantity,
	   I.price				  AS Price,
	   @count     			  AS Count
	    FROM inventory I JOIN #Temp_wholesalerreturn temp 
	   ON I.inventory_id=temp.InventoryId
	   where I.is_deleted!=1 AND pharmacy_id = @pharmacy_id AND (drug_name LIKE '%'+ISNULL(@SearchString,drug_name)+'%') 
		 ORDER BY inventory_id desc
		 OFFSET  @PageSize * (@PageNumber - 1)   ROWS
         FETCH NEXT @PageSize ROWS ONLY	

  END


--exec SP_returnToWholesaler 1,10,1,'3'






GO
/****** Object:  StoredProcedure [dbo].[SP_RevenueSummary]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Create date: <Create Date,2018-06-04>
-- Description:	<Description,Get the revenue summary details>
-- exec SP_RevenueSummary 1417
-- =============================================

CREATE PROC [dbo].[SP_RevenueSummary](
@pharmacyId			INT
)

AS
BEGIN
    --get the current year
	Declare @startyear datetime
	set @startyear = DATEADD(yy, DATEDIFF(yy, 0, GETDATE()), 0)
	
	--Get the Rx30_inventory details

	SELECT ISNULL(sum(plan_paid),0) AS Totalplanpaid,DATEPART(month, created_on) AS Month
	INTO #Temp_inv
    FROM RX30_inventory
    WHERE ((pharmacy_id=@pharmacyId ) AND
           (created_on BETWEEN  @startyear AND GETDATE()) AND (is_deleted IS NULL)
		   )
    GROUP BY DATEPART(month, created_on)

	
	--Get the COGS  from invoice and invoice_line_items
	SELECT DATEPART(month, I.created_on) AS Month,ISNULL(SUM(R.unit_price * CONVERT(int, R.invoiced_quantity)),0) AS cogsTotal
	INTO #Temp_invoicedata
	FROM invoice I JOIN invoice_line_items R
    ON I.invoice_id =R.invoice_id 
	WHERE ((I.pharmacy_id= @pharmacyId )
			AND
           (I.created_on BETWEEN  @startyear AND GETDATE()) AND (I.is_deleted =0)
		   )

    GROUP BY DATEPART(month, I.created_on)

	
	--Get the COGS  from csv import.
	INSERT INTO #Temp_invoicedata(Month,cogsTotal)
	SELECT DATEPART(month, wcibm.created_on) AS Month,ISNULL(SUM(wci.price* CONVERT(int, wci.pack_size)),0) AS cogsTotal
	FROM wholesaler_CSV_Import wci INNER JOIN wholesaler_csvimport_batch_master wcibm
    ON wci.csvbatch_id = wcibm.csvimport_batch_id 

	WHERE ((wcibm.pharmacy_id= @pharmacyId)
			AND
           (wcibm.created_on BETWEEN  @startyear AND GETDATE())
		   )
    GROUP BY DATEPART(month, wcibm.created_on)

	
	-- Update the price sum according to months for csv and invoice
	SELECT Month AS Month, sum(ISNULL(cogsTotal,0)) AS cogsTotal
	INTO #Temp_invoicedata1
	 FROM #Temp_invoicedata group by Month
	



   	-- TABLE FOR MONTH AND MONTH NAME
		SELECT LEFT(DATENAME(MONTH, DATEADD(MM, s.number, CONVERT(DATETIME, 0))),3) AS [MonthName], 
		MONTH(DATEADD(MM, s.number, CONVERT(DATETIME, 0))) AS [MonthNumber] 
		INTO #MONTH
		FROM master.dbo.spt_values s 
		WHERE [type] = 'P' AND s.number BETWEEN 0 AND 11
		ORDER BY 2
		
   --Join Month table and Rx30 plan paid

    SELECT ISNULL(I.Totalplanpaid,0) AS TotalPlanPaid,ISNULL(C.cogsTotal,0) AS cogsTotal,M.MonthName FROM #Temp_inv I
	RIGHT JOIN #MONTH M
	ON I.Month=M.MonthNumber
	LEFT JOIN #Temp_invoicedata1 C
	ON C.Month=M.MonthNumber
	DROP TABLE #Temp_inv
	DROP TABLE #MONTH
END

--drop table #Temp_invoicedata1

GO
/****** Object:  StoredProcedure [dbo].[SP_ReviewPostItemsList]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Create date: 04-05-2018
-- Description: SP to show Review posted item list with pagination and serarching
--SP_ReviewPostItemsList 1417,10,1,''
-- =============================================

CREATE PROC [dbo].[SP_ReviewPostItemsList]
  @pharmacy_id  int,
  @PageSize		int,
  @PageNumber    int,
  @SearchString  nvarchar(100)=null

	AS
   BEGIN
   DECLARE @count int;
   
  
	SELECT 
	     mp_postitem_id					  AS Id,
		 mp_network_type_id				  AS NetworkId,		
		 drug_name						  AS DrugName,
		 ndc_code						  AS NDC,
		 generic_code					  AS GenericCode,
		 pack_size						  AS PackSize,
		 strength						  AS Strength,					
		 base_price	                      AS BasePrice,
		 sales_price					  AS SalesPrice,
		 lot_number						  AS LOT,
		 exipry_date					  AS Expiry_date
		
		 INTO #Temp_list        
		 FROM [dbo].[mp_post_items] 
		 WHERE 	pharmacy_id = @pharmacy_id AND is_deleted IS NULL
		 
		   SELECT @count=COUNT(*) FROM #Temp_list

		SELECT 
		 Id,
		 NetworkId,		
		 DrugName,
		 NDC,
		 GenericCode,
		 PackSize,
		 Strength,		
		 BasePrice,
		 SalesPrice,
		 LOT,
		 Expiry_date,
		 @count as Count
		 FROM #Temp_list
		 WHERE
		  (DrugName LIKE '%'+ISNULL(@SearchString,DrugName)+'%' OR
		 NDC LIKE '%'+ISNULL(@SearchString,NDC)+'%') 
		 ORDER BY Id desc
		 OFFSET  @PageSize * (@PageNumber - 1)   ROWS
		 FETCH NEXT @PageSize ROWS ONLY	


  END




GO
/****** Object:  StoredProcedure [dbo].[SP_rx30_importList]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================

-- Author:      Priyanka Chandak

-- Create date: 27-03-2018

-- Description: SP to show Rx30 import list with server side pagination and searching



-- exec SP_rx30_importList 1417, 10,1,'68001011903'

-- =============================================

--drop proc SP_rx30_importList1



CREATE PROC [dbo].[SP_rx30_importList]



  @pharmacy_id    int,



  @PageSize		int,



  @PageNumber    int,  



  @SearchString  nvarchar(100)=null



  AS



   BEGIN

    DECLARE @count int;  	



	SELECT

	A.rx30_inventory_id AS Rx30InventoryId,

	A.drug_name          AS DrugName,

	A.ndc				 AS NDC,

	A.pharmacy_name		 AS PharmacyName,

	R.status_name		 AS Status,

	A.qty_disp			 AS Quantity,

	A.pack_size			 AS Packsize,

	A.created_on		 AS ImportDate

	into  #Temp_rx30_importList

	from RX30_inventory A 



	JOIN rx30_status_master R ON A.status=R.status_id

	WHERE A.pharmacy_id=@pharmacy_id AND A.is_deleted Is Null





	declare @sum decimal(10,2)

    SELECT  @count= IsNull (COUNT(*),0) FROM #Temp_rx30_importList where (DrugName LIKE '%'+ISNULL(@SearchString,DrugName)+'%' OR NDC LIKE '%'+ISNULL(@SearchString,NDC)+'%')



   -- UPDATE #Temp_rx30_importList SET Count=@count,TotalQuantity=@sum

   --,@sum = ISNULL(SUM(Quantity),0.0)





	 SELECT 

	  Rx30InventoryId,

	  DrugName,

	  NDC,

	  PharmacyName,

	  Status,

	  Quantity,

	  Packsize,

	  ImportDate, 

	  @count as Count

	  --@sum   as TotalQuantity

	  INTO #Temp_rx30_importListSUM

	  FROM #Temp_rx30_importList

	  WHERE (DrugName LIKE '%'+ISNULL(@SearchString,DrugName)+'%' OR NDC LIKE '%'+ISNULL(@SearchString,NDC)+'%')





	  SELECT @sum = ISNULL(SUM(Quantity),0.0) FROM #Temp_rx30_importListSUM



	  SELECT 

	  Rx30InventoryId,

	  DrugName,

	  NDC,

	  PharmacyName,

	  Status,

	  Quantity,

	  Packsize,

	  ImportDate, 

	  Count,

	  @sum   as TotalQuantity

	   FROM #Temp_rx30_importListSUM

	   ORDER BY Rx30InventoryId DESC

	  OFFSET  @PageSize * (@PageNumber - 1)   ROWS

      FETCH NEXT @PageSize ROWS ONLY





  END






GO
/****** Object:  StoredProcedure [dbo].[SP_rx30_importList_backUp_15-06-2018]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 27-03-2018
-- Description: SP to show Rx30 import list with server side pagination and searching

-- exec SP_rx30_importList 1417, 10,1,'00003089421'
-- =============================================
--drop proc SP_rx30_importList1

CREATE PROC [dbo].[SP_rx30_importList_backUp_15-06-2018]

  @pharmacy_id    int,

  @PageSize		int,

  @PageNumber    int,  

  @SearchString  nvarchar(100)=''

  AS

   BEGIN
    DECLARE @count int;  	
	Declare @ndc_search nvarchar(100);

	if try_convert(bigint,@SearchString)!=null
		set @ndc_search=convert(bigint,@SearchString)
		select ISNull(try_convert(bigint,@SearchString),-1),@ndc_search,@SearchString
	--declare @SearchString NVARCHAR(100) = '00003089421'

	SELECT
	A.rx30_inventory_id AS Rx30InventoryId,
	A.drug_name          AS DrugName,
	A.ndc				 AS NDC,
	A.pharmacy_name		 AS PharmacyName,
	R.status_name		 AS Status,
	A.qty_disp			 AS Quantity,
	A.pack_size			 AS Packsize,
	ISNull(A.created_on,getdate())		 AS ImportDate
	into #Temp_rx30_importList
	from RX30_inventory A 

	JOIN rx30_status_master R ON A.status=R.status_id
	WHERE A.pharmacy_id= 1417 --@pharmacy_id


	declare @sum decimal(10,2)
    --SELECT  @count= IsNull (COUNT(*),0) FROM #Temp_rx30_importList where ((DrugName LIKE '%'+ISNULL(@SearchString,DrugName)+'%') OR (NDC LIKE '%'+cast(cast(@SearchString as varchar) as bigint)+'%'))
	SELECT  @count= 11
   -- UPDATE #Temp_rx30_importList SET Count=@count,TotalQuantity=@sum
   --,@sum = ISNULL(SUM(Quantity),0.0)


	 SELECT 
	  Rx30InventoryId,
	  DrugName,
	  NDC,
	  PharmacyName,
	  Status,
	  Quantity,
	  Packsize,
	  ImportDate, 
	  @count as Count
	  --@sum   as TotalQuantity
	  INTO #Temp_rx30_importListSUM
	  FROM #Temp_rx30_importList
	  WHERE ((DrugName LIKE '%'+ISNULL(@SearchString,DrugName)+'%') 
	OR (cast(NDC as nvarchar) LIKE '%'+@ndc_search +'%')
	)

	  --drop table #Temp_rx30_importList
	  --drop table #Temp_rx30_importListSUM

	  SELECT @sum = ISNULL(SUM(Quantity),0.0) FROM #Temp_rx30_importListSUM

	  SELECT 
	  Rx30InventoryId,
	  DrugName,
	  NDC,
	  PharmacyName,
	  Status,
	  Quantity,
	  Packsize,
	  ImportDate, 
	  Count,
	  @sum   as TotalQuantity
	   FROM #Temp_rx30_importListSUM
	   ORDER BY Rx30InventoryId DESC
	  OFFSET  @PageSize * (@PageNumber - 1)   ROWS
      FETCH NEXT @PageSize ROWS ONLY


  END





GO
/****** Object:  StoredProcedure [dbo].[SP_rx30_importList111]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 27-03-2018
-- Description: SP to show Rx30 import list with server side pagination and searching

-- exec SP_rx30_importList 1417, 5,1,''
-- =============================================
--drop proc SP_rx30_importList1

Create PROC [dbo].[SP_rx30_importList111]

  @pharmacy_id    int,

  @PageSize		int,

  @PageNumber    int,  

  @SearchString  nvarchar(100)=null

  AS

   BEGIN
    DECLARE @count int;  	

	SELECT
	A.rx30_inventory_id AS Rx30InventoryId,
	A.drug_name          AS DrugName,
	A.ndc				 AS NDC,
	A.pharmacy_name		 AS PharmacyName,
	R.status_name		 AS Status,
	A.qty_disp			 AS Quantity,
	A.pack_size			 AS Packsize,
	A.created_on		 AS ImportDate
	into  #Temp_rx30_importList
	from RX30_inventory A 

	JOIN rx30_status_master R ON A.status=R.status_id
	WHERE A.pharmacy_id=@pharmacy_id


	declare @sum decimal(10,2)
    SELECT  @count= IsNull (COUNT(*),0) FROM #Temp_rx30_importList where (DrugName LIKE '%'+ISNULL(@SearchString,DrugName)+'%' OR NDC LIKE '%'+ISNULL(@SearchString,NDC)+'%')

   -- UPDATE #Temp_rx30_importList SET Count=@count,TotalQuantity=@sum
   --,@sum = ISNULL(SUM(Quantity),0.0)


	 SELECT 
	  Rx30InventoryId,
	  DrugName,
	  NDC,
	  PharmacyName,
	  Status,
	  Quantity,
	  Packsize,
	  ImportDate, 
	  @count as Count
	  --@sum   as TotalQuantity
	  INTO #Temp_rx30_importListSUM
	  FROM #Temp_rx30_importList
	  WHERE (DrugName LIKE '%'+ISNULL(@SearchString,DrugName)+'%' OR NDC LIKE '%'+ISNULL(@SearchString,NDC)+'%')


	  SELECT @sum = ISNULL(SUM(Quantity),0.0) FROM #Temp_rx30_importListSUM

	  SELECT 
	  Rx30InventoryId,
	  DrugName,
	  NDC,
	  PharmacyName,
	  Status,
	  Quantity,
	  Packsize,
	  ImportDate, 
	  Count,
	  @sum   as TotalQuantity
	   FROM #Temp_rx30_importListSUM
	   ORDER BY Rx30InventoryId DESC
	  OFFSET  @PageSize * (@PageNumber - 1)   ROWS
      FETCH NEXT @PageSize ROWS ONLY


  END




GO
/****** Object:  StoredProcedure [dbo].[SP_RX30_Inventory_Processor]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================

-- Author:     

-- Create date: 

-- Description: SP to Update the inventory after RX30 file.

-- =============================================

--exec SP_RX30_Inventory_Processor

CREATE PROC [dbo].[SP_RX30_Inventory_Processor]  

	AS
   BEGIN
	   BEGIN TRY
				INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_RX30_Inventory_Processor', GETDATE(),'RX30 data Processor','IN SP_RX30_Inventory_Processor.'); 

			DECLARE @STATUS_NEW			INT
			DECLARE @STATUS_PROCESSED	INT
      

			SET @STATUS_NEW = 1 /*NEW*/
			SET @STATUS_PROCESSED = 2 /*Processed*/   

			CREATE TABLE #pending_rx30_inventory(

					row_id				INT IDENTITY (1,1),			
					[ndc]				BIGINT,
					[qty_disp]			DECIMAL(10,3),			
					[pharmacy_id]		INT,
					[is_processed]		INT,	/*add new column to avoid update rx30 if inventory table does not have ndc, 1 if ndc proccessed, */	
					/*Begin: PrashantW: Added new colums for -ve inventory.*/
					rx30_inventory_id   INT,
					rx30_batch_details_id INT			
					/*End: PrashantW: Added new colums for -ve inventory.*/
			)
   
			INSERT INTO #pending_rx30_inventory
				SELECT 
						--[rx30_inventory_id] ,
						inv_rx30.[ndc],
						/*SUM(inv_rx30.qty_disp) AS qty_disp,*/				
						inv_rx30.qty_disp AS qty_disp,
						inv_rx30.pharmacy_id,
						0
						/*Begin: PrashantW: Added new colums for -ve inventory.*/
						,rx30_inventory_id
						,rx30_batch_details_id
						/*End: PrashantW: Added new colums for -ve inventory.*/				
				FROM [dbo].[RX30_inventory] inv_rx30
				/*Begin: PrashantW: Commenting group by and rewriting for -ve inventory.		
				GROUP BY ndc,pharmacy_id,inv_rx30.status
				HAVING inv_rx30.status = @STATUS_NEW
				*/
				WHERE inv_rx30.status = @STATUS_NEW
				/*End: PrashantW: Commenting group by and rewriting for -ve inventory.*/

				--Update the pack size as per as ndc in temp table

				--Update tempPrx set
				--	tempPrx.ndc_packsize = inv_Rx30.pack_size
				--from #pending_rx30_inventory tempPrx
				--INNER JOIN RX30_inventory inv_Rx30 ON tempPrx.ndc = inv_Rx30.ndc

			DECLARE @count INT;
			SELECT  @count= count(*) FROM #pending_rx30_inventory	  

			INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_RX30_Inventory_Processor', GETDATE(),'RX30 data Processor','count='+ CONVERT(varchar, @count)); 
	
			DECLARE @index INT =1;	   

			WHILE(@index <= @count)  /*WHILE1*/
			BEGIN  
				DECLARE @ndc BIGINT, @ph_id INT, @qty_disp DECIMAL(10,3);
				--DECLARE @ndc_PackSize DECIMAL(10,2);	
				/*Begin: PrashantW: add -ve inventory to container, Added new variables*/
				DECLARE @rx30_inventory_id INT, @rx30_batch_details_id INT
				/*End: PrashantW: add -ve inventory to container, Added new variables*/

				/*Begin: PrashantW: commneted and rewrote for -ve inventory.*/
				/*SELECT @ndc=ndc, @ph_id=pharmacy_id, @qty_disp= qty_disp  FROM #pending_rx30_inventory WHERE row_id=@index;*/
				SELECT	@ndc					=		ndc, 
						@ph_id					=		pharmacy_id, 
						@qty_disp				=		qty_disp, 
						@rx30_inventory_id		=		rx30_inventory_id,
						@rx30_batch_details_id	=		rx30_batch_details_id  
				FROM #pending_rx30_inventory 
				WHERE row_id=@index;
				/*End: PrashantW: commneted and rewrote for -ve inventory.*/

				WHILE(@qty_disp > 0) /*WHILE2*/
				BEGIN

						DECLARE @QOH  DECIMAL(10,2);
						DECLARE @inventory_id  INT;

						-- fetching inventory data having same ndc and pharmacy as in above variable.

						SELECT  @QOH = inv_b.pack_size, @inventory_id = inv_b.inventory_id  from inventory inv_b WHERE inv_b.inventory_id =

							(SELECT TOP 1 MIN(inv_a.inventory_id) FROM inventory inv_a WHERE inv_a.ndc = @ndc AND inv_a.pharmacy_id = @ph_id AND inv_a.pack_size >0 AND ISNULL(inv_a.is_deleted,0) = 0 ) 

					IF(ISNULL(@inventory_id,0) > 0)
					BEGIN
				
						IF((@qty_disp > @QOH) AND (@QOH > 0) )
						BEGIN
							print 'if1'
							print(CAST(@inventory_id AS VARCHAR(20)) )
							Update inventory SET pack_size = 0,  is_deleted = 1 WHERE inventory_id = @inventory_id
							SET @qty_disp = @qty_disp-@QOH;
							/*update proccessed column into temp*/   
								UPDATE #pending_rx30_inventory SET is_processed = 1 WHERE row_id=@index	
						END		 
						ELSE
						BEGIN
							print 'else1'
							print(CAST(@inventory_id AS VARCHAR(20)) )
							DECLARE @pack_size  DECIMAL(10,2);
					
							SET @pack_size = (@QOH-@qty_disp)
							SET @qty_disp = @qty_disp - @QOH;
							IF (@pack_size <=0)
							BEGIN
								Update inventory SET pack_size = 0,  is_deleted = 1 WHERE inventory_id = @inventory_id							
							END
							ELSE
							BEGIN
								Update inventory SET pack_size = @pack_size WHERE inventory_id = @inventory_id
							END					
					
							/*update proccessed column into temp*/   
								UPDATE #pending_rx30_inventory SET is_processed = 1 WHERE row_id=@index	
								print(CAST(@pack_size AS VARCHAR(20)) )
								SET @pack_size = 0
						END
						SET @inventory_id = 0
					END
					ELSE
					BEGIN
						print 'else2'				
						/*Begin: PrashantW: add -ve inventory to container.					 
								*/
								INSERT INTO [dbo].[pending_reorder] (							
									ndc,
									qty_reorder,	
									pharmacy_id,
									rx30_inventory_id,
									rx30_batch_details_id,
									inventory_id,
									created_on	
								) VALUES (

									@ndc,
									@qty_disp,
									@ph_id,
									@rx30_inventory_id,
									@rx30_batch_details_id,
									@inventory_id,
									GETDATE()
								)
								UPDATE #pending_rx30_inventory SET is_processed = 1 WHERE row_id=@index
								INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_RX30_Inventory_Processor', GETDATE(),'RX30 data Processor','NDC not found for substract/negative. Quantity disp added to reorder container. NDC=' + CAST(@ndc AS VARCHAR(20)) + ' qty_disp=' + CAST(@qty_disp AS VARCHAR(20)) + ' rx30_inventory_id=' + CAST(@rx30_inventory_id AS VARCHAR(20))); 					
								SET @qty_disp = 0 /*To close while loop*/
								/*End: PrashantW: add -ve inventory to container*/									
				
					END			     				

					END /*WHILE2*/

				SET @index=@index+1

			END  /*WHILE1*/

			INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_RX30_Inventory_Processor', GETDATE(),'RX30 data Processor','END calling the SP_RX30_Inventory_Processor'); 

  

			UPDATE inv_rx30
				SET inv_rx30.status = @STATUS_PROCESSED
			FROM [RX30_inventory] inv_rx30
			INNER JOIN #pending_rx30_inventory inv_rx30_tmp on inv_rx30_tmp.ndc = inv_rx30.ndc
			WHERE inv_rx30.status = @STATUS_NEW 	AND inv_rx30_tmp.is_processed = 1	 	
	
	
			DROP TABLE #pending_rx30_inventory   
	   END TRY
	   BEGIN CATCH
			INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_RX30_Inventory_Processor', GETDATE(),'Error','ERROR_LINE: ' + CAST(ERROR_LINE() AS VARCHAR(20)) + ' ERROR_MESSAGE:  '  + ERROR_MESSAGE()); 		
	   END CATCH
   
  END











GO
/****** Object:  StoredProcedure [dbo].[SP_RX30_Inventory_Processor_backup_13_06_2018]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================

-- Author:     

-- Create date: 

-- Description: SP to Update the inventory after RX30 file.

-- =============================================

--exec SP_RX30_Inventory_Processor

CREATE PROC [dbo].[SP_RX30_Inventory_Processor_backup_13_06_2018]

  

	AS

   BEGIN

   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_RX30_Inventory_Processor', GETDATE(),'RX30 data Processor','IN SP_RX30_Inventory_Processor.'); 

   DECLARE @STATUS_NEW			INT

   DECLARE @STATUS_PROCESSED	INT

   

   

   SET @STATUS_NEW = 1 /*NEW*/

   SET @STATUS_PROCESSED = 2 /*Processed*/



  

   CREATE TABLE #pending_rx30_inventory(

			row_id				INT IDENTITY (1,1),			

			[ndc]				BIGINT,

			[qty_disp]			DECIMAL(10,3),			

			[pharmacy_id]		INT,

			[ndc_packsize]		DECIMAL(10,2)

			

   )

   

   INSERT INTO #pending_rx30_inventory

	   SELECT 

				--[rx30_inventory_id] ,

				inv_rx30.[ndc],

				SUM(inv_rx30.qty_disp) AS qty_disp,				

				inv_rx30.pharmacy_id,
				0

		FROM [dbo].[RX30_inventory] inv_rx30		

		GROUP BY ndc,pharmacy_id,inv_rx30.status

		HAVING inv_rx30.status = @STATUS_NEW



		--Update the pack size as per as ndc in temp table

		Update tempPrx set

		tempPrx.ndc_packsize = inv_Rx30.pack_size

		from #pending_rx30_inventory tempPrx

		INNER JOIN RX30_inventory inv_Rx30 ON tempPrx.ndc = inv_Rx30.ndc





   DECLARE @count INT;



    SELECT  @count= count(*) FROM #pending_rx30_inventory

	  

	INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_RX30_Inventory_Processor', GETDATE(),'RX30 data Processor','count='+ CONVERT(varchar, @count)); 

	

	Declare @index INT =1;

   

	WHILE(@index <= @count)

	BEGIN  

		DECLARE @ndc BIGINT, @ph_id INT, @qty_disp DECIMAL(10,3);

		DECLARE @ndc_PackSize DECIMAL(10,2);

	

		SELECT @ndc=ndc, @ph_id=pharmacy_id, @qty_disp= (qty_disp /ndc_packsize) , @ndc_PackSize=ndc_packsize   FROM #pending_rx30_inventory WHERE row_id=@index;



		 WHILE(@qty_disp > 0)

		 BEGIN

			 DECLARE @QOH  INT;

			 -- fetching inventory data having same ndc and pharmacy as in above variable.

			 SELECT  @QOH = inv_b.pack_size from inventory inv_b WHERE inv_b.inventory_id =

				 (SELECT TOP 1 MIN(inv_a.inventory_id) FROM inventory inv_a WHERE inv_a.ndc = @ndc AND inv_a.pharmacy_id = @ph_id AND inv_a.pack_size >0 AND inv_a.is_deleted = 0 )

			     

	

			IF((@qty_disp > @QOH) AND (@QOH > 0) )

			BEGIN

				Update inventory SET pack_size = 0, NDC_Packsize = @ndc_PackSize, is_deleted = 1 Where ndc = @ndc 

				SET @qty_disp = @qty_disp-@QOH;

			END		 

			ELSE

			BEGIN

				Update inventory SET pack_size = (@QOH-@qty_disp), NDC_Packsize = @ndc_PackSize Where ndc = @ndc 

				SET @qty_disp = 0;

			END

		 END

		SET @index=@index+1

	END  



   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_RX30_Inventory_Processor', GETDATE(),'RX30 data Processor','END calling the SP_RX30_Inventory_Processor'); 

  

   UPDATE inv_rx30

		SET inv_rx30.status = @STATUS_PROCESSED

   FROM [RX30_inventory] inv_rx30

   WHERE inv_rx30.status = @STATUS_NEW 			

	

   DROP TABLE #pending_rx30_inventory   

 

  END








GO
/****** Object:  StoredProcedure [dbo].[SP_RX30_Inventory_Processor_backup_yaron]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO



-- =============================================

-- Author:     

-- Create date: 

-- Description: SP to Update the inventory after RX30 file.

-- =============================================

--exec SP_RX30_Inventory_Processor

CREATE PROC [dbo].[SP_RX30_Inventory_Processor_backup_yaron]

  

	AS

   BEGIN

   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_RX30_Inventory_Processor', GETDATE(),'RX30 data Processor','IN SP_RX30_Inventory_Processor.'); 

   DECLARE @STATUS_NEW			INT
   DECLARE @STATUS_PROCESSED	INT
      

   SET @STATUS_NEW = 1 /*NEW*/
   SET @STATUS_PROCESSED = 2 /*Processed*/   

   CREATE TABLE #pending_rx30_inventory(

			row_id				INT IDENTITY (1,1),			
			[ndc]				BIGINT,
			[qty_disp]			DECIMAL(10,3),			
			[pharmacy_id]		INT
			--,[ndc_packsize]		DECIMAL(10,2)		
   )
   
   INSERT INTO #pending_rx30_inventory
	   SELECT 
				--[rx30_inventory_id] ,
				inv_rx30.[ndc],
				SUM(inv_rx30.qty_disp) AS qty_disp,				
				inv_rx30.pharmacy_id
				--,0
		FROM [dbo].[RX30_inventory] inv_rx30		
		GROUP BY ndc,pharmacy_id,inv_rx30.status
		HAVING inv_rx30.status = @STATUS_NEW
		

		--Update the pack size as per as ndc in temp table

		--Update tempPrx set
		--	tempPrx.ndc_packsize = inv_Rx30.pack_size
		--from #pending_rx30_inventory tempPrx
		--INNER JOIN RX30_inventory inv_Rx30 ON tempPrx.ndc = inv_Rx30.ndc

	DECLARE @count INT;
    SELECT  @count= count(*) FROM #pending_rx30_inventory	  

	INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_RX30_Inventory_Processor', GETDATE(),'RX30 data Processor','count='+ CONVERT(varchar, @count)); 
	
	DECLARE @index INT =1;	   

	WHILE(@index <= @count)
	BEGIN  
		DECLARE @ndc BIGINT, @ph_id INT, @qty_disp DECIMAL(10,3);
		--DECLARE @ndc_PackSize DECIMAL(10,2);	

		SELECT @ndc=ndc, @ph_id=pharmacy_id, @qty_disp= qty_disp  FROM #pending_rx30_inventory WHERE row_id=@index;
		
		WHILE(@qty_disp > 0)
		BEGIN

			 DECLARE @QOH  DECIMAL(10,2);
			 DECLARE @inventory_id  INT;

			 -- fetching inventory data having same ndc and pharmacy as in above variable.

			 SELECT  @QOH = inv_b.pack_size, @inventory_id = inv_b.inventory_id  from inventory inv_b WHERE inv_b.inventory_id =

				 (SELECT TOP 1 MIN(inv_a.inventory_id) FROM inventory inv_a WHERE inv_a.ndc = @ndc AND inv_a.pharmacy_id = @ph_id AND inv_a.pack_size >0 AND inv_a.is_deleted = 0 ) 

			     	
			IF((@qty_disp > @QOH) AND (@QOH > 0) )
			BEGIN
				Update inventory SET pack_size = 0,  is_deleted = 1 WHERE inventory_id = @inventory_id
				SET @qty_disp = @qty_disp-@QOH;
			END		 
			ELSE
			BEGIN
				Update inventory SET pack_size = (@QOH-@qty_disp) WHERE inventory_id = @inventory_id
				SET @qty_disp = @qty_disp - @QOH;
			END

		 END

		SET @index=@index+1

	END  



   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_RX30_Inventory_Processor', GETDATE(),'RX30 data Processor','END calling the SP_RX30_Inventory_Processor'); 

  

   UPDATE inv_rx30
		SET inv_rx30.status = @STATUS_PROCESSED
   FROM [RX30_inventory] inv_rx30
   WHERE inv_rx30.status = @STATUS_NEW 			
	
	
   DROP TABLE #pending_rx30_inventory   
  END








GO
/****** Object:  StoredProcedure [dbo].[SP_RX30_Inventory_Processor_backup26-06-2018]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================

-- Author:     

-- Create date: 

-- Description: SP to Update the inventory after RX30 file.

-- =============================================

--exec SP_RX30_Inventory_Processor

Create PROC [dbo].[SP_RX30_Inventory_Processor_backup26-06-2018]

  

	AS

   BEGIN

   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_RX30_Inventory_Processor', GETDATE(),'RX30 data Processor','IN SP_RX30_Inventory_Processor.'); 

   DECLARE @STATUS_NEW			INT
   DECLARE @STATUS_PROCESSED	INT
      

   SET @STATUS_NEW = 1 /*NEW*/
   SET @STATUS_PROCESSED = 2 /*Processed*/   

   CREATE TABLE #pending_rx30_inventory(

			row_id				INT IDENTITY (1,1),			
			[ndc]				BIGINT,
			[qty_disp]			DECIMAL(10,3),			
			[pharmacy_id]		INT,
			[ndc_packsize]		DECIMAL(10,2)		
   )
   
   INSERT INTO #pending_rx30_inventory
	   SELECT 
				--[rx30_inventory_id] ,
				inv_rx30.[ndc],
				SUM(inv_rx30.qty_disp) AS qty_disp,				
				inv_rx30.pharmacy_id,
				0
		FROM [dbo].[RX30_inventory] inv_rx30		
		GROUP BY ndc,pharmacy_id,inv_rx30.status
		HAVING inv_rx30.status = @STATUS_NEW
		

		--Update the pack size as per as ndc in temp table

		Update tempPrx set
			tempPrx.ndc_packsize = inv_Rx30.pack_size
		from #pending_rx30_inventory tempPrx
		INNER JOIN RX30_inventory inv_Rx30 ON tempPrx.ndc = inv_Rx30.ndc

	DECLARE @count INT;
    SELECT  @count= count(*) FROM #pending_rx30_inventory	  

	INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_RX30_Inventory_Processor', GETDATE(),'RX30 data Processor','count='+ CONVERT(varchar, @count)); 
	
	DECLARE @index INT =1;	   

	WHILE(@index <= @count)
	BEGIN  
		DECLARE @ndc BIGINT, @ph_id INT, @qty_disp DECIMAL(10,3);
		DECLARE @ndc_PackSize DECIMAL(10,2);	

		SELECT @ndc=ndc, @ph_id=pharmacy_id, @qty_disp= (qty_disp /ndc_packsize) , @ndc_PackSize=ndc_packsize   FROM #pending_rx30_inventory WHERE row_id=@index;
		
		WHILE(@qty_disp > 0)
		BEGIN

			 DECLARE @QOH  INT;
			 DECLARE @inventory_id  INT;

			 -- fetching inventory data having same ndc and pharmacy as in above variable.

			 SELECT  @QOH = inv_b.pack_size, @inventory_id = inv_b.inventory_id  from inventory inv_b WHERE inv_b.inventory_id =

				 (SELECT TOP 1 MIN(inv_a.inventory_id) FROM inventory inv_a WHERE inv_a.ndc = @ndc AND inv_a.pharmacy_id = @ph_id AND inv_a.pack_size >0 AND inv_a.is_deleted = 0 ) 

			     	
			IF((@qty_disp > @QOH) AND (@QOH > 0) )
			BEGIN
				Update inventory SET pack_size = 0, NDC_Packsize = @ndc_PackSize, is_deleted = 1 WHERE inventory_id = @inventory_id
				SET @qty_disp = @qty_disp-@QOH;
			END		 
			ELSE
			BEGIN
				Update inventory SET pack_size = (@QOH-@qty_disp), NDC_Packsize = @ndc_PackSize WHERE inventory_id = @inventory_id
				SET @qty_disp = @qty_disp - @QOH;
			END

		 END

		SET @index=@index+1

	END  



   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_RX30_Inventory_Processor', GETDATE(),'RX30 data Processor','END calling the SP_RX30_Inventory_Processor'); 

  

   UPDATE inv_rx30
		SET inv_rx30.status = @STATUS_PROCESSED
   FROM [RX30_inventory] inv_rx30
   WHERE inv_rx30.status = @STATUS_NEW 			
	
	
   DROP TABLE #pending_rx30_inventory   
  END








GO
/****** Object:  StoredProcedure [dbo].[SP_RX30_Inventory_Processor_bk_04132019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================

-- Author:     

-- Create date: 

-- Description: SP to Update the inventory after RX30 file.

-- =============================================

--exec SP_RX30_Inventory_Processor

CREATE PROC [dbo].[SP_RX30_Inventory_Processor_bk_04132019]

  

	AS

   BEGIN

   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_RX30_Inventory_Processor', GETDATE(),'RX30 data Processor','IN SP_RX30_Inventory_Processor.'); 

   DECLARE @STATUS_NEW			INT
   DECLARE @STATUS_PROCESSED	INT
      

   SET @STATUS_NEW = 1 /*NEW*/
   SET @STATUS_PROCESSED = 2 /*Processed*/   

   CREATE TABLE #pending_rx30_inventory(

			row_id				INT IDENTITY (1,1),			
			[ndc]				BIGINT,
			[qty_disp]			DECIMAL(10,3),			
			[pharmacy_id]		INT
			--,[ndc_packsize]		DECIMAL(10,2)		
   )
   
   INSERT INTO #pending_rx30_inventory
	   SELECT 
				--[rx30_inventory_id] ,
				inv_rx30.[ndc],
				SUM(inv_rx30.qty_disp) AS qty_disp,				
				inv_rx30.pharmacy_id
				--,0
		FROM [dbo].[RX30_inventory] inv_rx30		
		GROUP BY ndc,pharmacy_id,inv_rx30.status
		HAVING inv_rx30.status = @STATUS_NEW
		

		--Update the pack size as per as ndc in temp table

		--Update tempPrx set
		--	tempPrx.ndc_packsize = inv_Rx30.pack_size
		--from #pending_rx30_inventory tempPrx
		--INNER JOIN RX30_inventory inv_Rx30 ON tempPrx.ndc = inv_Rx30.ndc

	DECLARE @count INT;
    SELECT  @count= count(*) FROM #pending_rx30_inventory	  

	INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_RX30_Inventory_Processor', GETDATE(),'RX30 data Processor','count='+ CONVERT(varchar, @count)); 
	
	DECLARE @index INT =1;	   

	WHILE(@index <= @count)
	BEGIN  
		DECLARE @ndc BIGINT, @ph_id INT, @qty_disp DECIMAL(10,3);
		--DECLARE @ndc_PackSize DECIMAL(10,2);	

		SELECT @ndc=ndc, @ph_id=pharmacy_id, @qty_disp= qty_disp  FROM #pending_rx30_inventory WHERE row_id=@index;
		
		WHILE(@qty_disp > 0)
		BEGIN

			 DECLARE @QOH  DECIMAL(10,2);
			 DECLARE @inventory_id  INT;

			 -- fetching inventory data having same ndc and pharmacy as in above variable.

			 SELECT  @QOH = inv_b.pack_size, @inventory_id = inv_b.inventory_id  from inventory inv_b WHERE inv_b.inventory_id =

				 (SELECT TOP 1 MIN(inv_a.inventory_id) FROM inventory inv_a WHERE inv_a.ndc = @ndc AND inv_a.pharmacy_id = @ph_id AND inv_a.pack_size >0 AND inv_a.is_deleted = 0 ) 

			     	
			IF((@qty_disp > @QOH) AND (@QOH > 0) )
			BEGIN
				Update inventory SET pack_size = 0,  is_deleted = 1 WHERE inventory_id = @inventory_id
				SET @qty_disp = @qty_disp-@QOH;
			END		 
			ELSE
			BEGIN
				Update inventory SET pack_size = (@QOH-@qty_disp) WHERE inventory_id = @inventory_id
				SET @qty_disp = @qty_disp - @QOH;
			END

		 END

		SET @index=@index+1

	END  



   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_RX30_Inventory_Processor', GETDATE(),'RX30 data Processor','END calling the SP_RX30_Inventory_Processor'); 

  

   UPDATE inv_rx30
		SET inv_rx30.status = @STATUS_PROCESSED
   FROM [RX30_inventory] inv_rx30
   WHERE inv_rx30.status = @STATUS_NEW 			
	
	
   DROP TABLE #pending_rx30_inventory   
  END









GO
/****** Object:  StoredProcedure [dbo].[SP_RX30_Inventory_Processor_bk_20052019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================

-- Author:     

-- Create date: 

-- Description: SP to Update the inventory after RX30 file.

-- =============================================

--exec SP_RX30_Inventory_Processor

CREATE PROC [dbo].[SP_RX30_Inventory_Processor_bk_20052019]  

	AS
   BEGIN

   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_RX30_Inventory_Processor', GETDATE(),'RX30 data Processor','IN SP_RX30_Inventory_Processor.'); 

   DECLARE @STATUS_NEW			INT
   DECLARE @STATUS_PROCESSED	INT
      

   SET @STATUS_NEW = 1 /*NEW*/
   SET @STATUS_PROCESSED = 2 /*Processed*/   

   CREATE TABLE #pending_rx30_inventory(

			row_id				INT IDENTITY (1,1),			
			[ndc]				BIGINT,
			[qty_disp]			DECIMAL(10,3),			
			[pharmacy_id]		INT,
			[is_processed]		INT	/*add new column to avoid update rx30 if inventory table does not have ndc, 1 if ndc proccessed, */	
   )
   
   INSERT INTO #pending_rx30_inventory
	   SELECT 
				--[rx30_inventory_id] ,
				inv_rx30.[ndc],
				SUM(inv_rx30.qty_disp) AS qty_disp,				
				inv_rx30.pharmacy_id
				,0
		FROM [dbo].[RX30_inventory] inv_rx30		
		GROUP BY ndc,pharmacy_id,inv_rx30.status
		HAVING inv_rx30.status = @STATUS_NEW
		

		--Update the pack size as per as ndc in temp table

		--Update tempPrx set
		--	tempPrx.ndc_packsize = inv_Rx30.pack_size
		--from #pending_rx30_inventory tempPrx
		--INNER JOIN RX30_inventory inv_Rx30 ON tempPrx.ndc = inv_Rx30.ndc

	DECLARE @count INT;
    SELECT  @count= count(*) FROM #pending_rx30_inventory	  

	INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_RX30_Inventory_Processor', GETDATE(),'RX30 data Processor','count='+ CONVERT(varchar, @count)); 
	
	DECLARE @index INT =1;	   

	WHILE(@index <= @count)  /*WHILE1*/
	BEGIN  
		DECLARE @ndc BIGINT, @ph_id INT, @qty_disp DECIMAL(10,3);
		--DECLARE @ndc_PackSize DECIMAL(10,2);	

		SELECT @ndc=ndc, @ph_id=pharmacy_id, @qty_disp= qty_disp  FROM #pending_rx30_inventory WHERE row_id=@index;
		
		WHILE(@qty_disp > 0) /*WHILE2*/
		BEGIN

			 DECLARE @QOH  DECIMAL(10,2);
			 DECLARE @inventory_id  INT;

			 -- fetching inventory data having same ndc and pharmacy as in above variable.

			 SELECT  @QOH = inv_b.pack_size, @inventory_id = inv_b.inventory_id  from inventory inv_b WHERE inv_b.inventory_id =

				 (SELECT TOP 1 MIN(inv_a.inventory_id) FROM inventory inv_a WHERE inv_a.ndc = @ndc AND inv_a.pharmacy_id = @ph_id AND inv_a.pack_size >0 AND inv_a.is_deleted = 0 ) 

			IF(ISNULL(@inventory_id,0) > 0)
			BEGIN
				
				IF((@qty_disp > @QOH) AND (@QOH > 0) )
				BEGIN
					print 'if1'
					print(CAST(@inventory_id AS VARCHAR(20)) )
					Update inventory SET pack_size = 0,  is_deleted = 1 WHERE inventory_id = @inventory_id
					SET @qty_disp = @qty_disp-@QOH;
					/*update proccessed column into temp*/   
					 UPDATE #pending_rx30_inventory SET is_processed = 1 WHERE row_id=@index	
				END		 
				ELSE
				BEGIN
					print 'else1'
					print(CAST(@inventory_id AS VARCHAR(20)) )
					Update inventory SET pack_size = (@QOH-@qty_disp) WHERE inventory_id = @inventory_id
					SET @qty_disp = @qty_disp - @QOH;
					/*update proccessed column into temp*/   
					 UPDATE #pending_rx30_inventory SET is_processed = 1 WHERE row_id=@index	
				END
				SET @inventory_id = 0
			END
			ELSE
			BEGIN
				print 'else2'
			 	SELECT  @QOH = inv_b.pack_size, @inventory_id = inv_b.inventory_id  from inventory inv_b WHERE inv_b.inventory_id =

			 (SELECT TOP 1 MAX(inv_a.inventory_id) FROM inventory inv_a WHERE inv_a.ndc = @ndc AND inv_a.pharmacy_id = @ph_id /*AND inv_a.pack_size = 0 AND inv_a.is_deleted = 1 */) 
				
				IF ISNULL(@inventory_id,0) >0
				 BEGIN
					 UPDATE inventory SET pack_size = @QOH - @qty_disp, is_deleted = 0 WHERE inventory_id = @inventory_id
					SET @qty_disp = @QOH - @qty_disp;
					 /*update proccessed column into temp*/   
					 UPDATE #pending_rx30_inventory SET is_processed = 1 WHERE row_id=@index
					 INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_RX30_Inventory_Processor', GETDATE(),'RX30 data Processor','Adding Negative inventory, inventory_id = ' + CAST(@inventory_id AS VARCHAR(20)) + ' ndc=' + CAST(@ndc AS VARCHAR(20)) + ' Q
uantity=' + CAST(@qty_disp AS VARCHAR(20))); 				
				 END
				ELSE
				BEGIN
					SET @qty_disp = 0 /*To close while loop*/
					INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_RX30_Inventory_Processor', GETDATE(),'RX30 data Processor','NDC not found for substract/negative. NDC=' + CAST(@ndc AS VARCHAR(20))); 					
				END	
			END			     				

		 END /*WHILE2*/

		SET @index=@index+1

	END  /*WHILE1*/

   INSERT INTO LOG(Application, Logged, Level, Message) VALUES('SP_RX30_Inventory_Processor', GETDATE(),'RX30 data Processor','END calling the SP_RX30_Inventory_Processor'); 

  

   UPDATE inv_rx30
		SET inv_rx30.status = @STATUS_PROCESSED
   FROM [RX30_inventory] inv_rx30
   INNER JOIN #pending_rx30_inventory inv_rx30_tmp on inv_rx30_tmp.ndc = inv_rx30.ndc
   WHERE inv_rx30.status = @STATUS_NEW 	AND inv_rx30_tmp.is_processed = 1	 	
	
	
   DROP TABLE #pending_rx30_inventory   
  END









GO
/****** Object:  StoredProcedure [dbo].[SP_sa_dashboard_bricks]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO




-- =============================================

-- Author:      Sagar Sharma

-- Create date: 08-05-2018

-- Description: SP to get the count of active customer/pharmacy owners, monitered pharmacies/pharmacies , monthly revenue, subscription expired. 
-- EXEC SP_sa_dashboard_bricks
-- =============================================



CREATE PROC [dbo].[SP_sa_dashboard_bricks]

  

	AS

   BEGIN

   DECLARE @activeCustomer INT;

   DECLARE @moniteredPharmacies INT;

   DECLARE @monthlyRevenue MONEY;

   DECLARE @subscriptionExpired INT;





   SELECT @activeCustomer = COUNT(*) FROM sa_pharmacy_owner WHERE is_deleted = 0;



   SELECT @moniteredPharmacies = COUNT(*) FROM pharmacy_list WHERE is_deleted = 0;



   SELECT @monthlyRevenue =  SUM(amount) from  payments WHERE MONTH(created_on) = Month(GETDATE()) AND YEAR(created_on) = YEAR(GETDATE())
   

   SELECT @subscriptionExpired =  COUNT(PlanExpireDT) FROM pharmacy_list WHERE PlanExpireDT<GETDATE() AND is_deleted=0







   



   SELECT @activeCustomer		AS ActiveCustomer,

		  @moniteredPharmacies	AS MoniteredPharmacies,

		  @monthlyRevenue		AS MonthlyRevenue,

		  @subscriptionExpired	AS SubscriptionExpired;



  END





  --EXEC SP_sa_dashboard_bricks




GO
/****** Object:  StoredProcedure [dbo].[SP_saDelete_Pharmacy]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================

-- Author:      Priyanka Chandak

-- Create date: 27-02-2018

-- Description: SP to SOFT DELETE pharmacy owner

-- =============================================



CREATE PROCEDURE [dbo].[SP_saDelete_Pharmacy](
	@id int,
	@deleted_by int
)
  AS 
  IF (@id IS NOT NULL)
	BEGIN
	--Set is_deleted to true in pharmacylist and pharmacyaddress table

	 UPDATE pharmacy_list SET deleted_by=@deleted_by,deleted_on=GETDATE(),is_deleted=1 WHERE pharmacy_id=@id
	 UPDATE sa_superAdmin_sddress SET deleted_by=@deleted_by,deleted_on=GETDATE(),is_deleted=1 WHERE pharmacy_id=@id

	 --Delete pharmacy from Users(Login) Table

	 DELETE FROM users WHERE pharmacy_id=@id


	return '1'

    END


	








GO
/****** Object:  StoredProcedure [dbo].[SP_saDelete_subscription]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 27-02-2018
-- Description: SP to ADD/UPDATE From Subscription table
-- =============================================

CREATE PROCEDURE [dbo].[SP_saDelete_subscription](
	@id int,
	@deleted_by int
)
  AS 
 
  IF (@id IS NOT NULL) OR (LEN(@id) > 0)
	BEGIN
	 UPDATE sa_subscription_plan SET deleted_by=@deleted_by,deleted_on=GETDATE(),is_deleted=1 WHERE subscription_plan_id=@id
	
    END




GO
/****** Object:  StoredProcedure [dbo].[SP_saInvoiceList]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO




-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 01-06-2018
-- Description: SP to show invoice list with pagination and serarching
-- SP_saInvoiceList 2,1,''
-- =============================================

CREATE PROC [dbo].[SP_saInvoiceList]
  @PageSize		int,
  @PageNumber    int,
  @SearchString  nvarchar(100)=null

	AS
   BEGIN
   DECLARE @count int;    

   SELECT 
   p.paymentId				AS PaymentId,
   p.pharmacy_id			AS PharmacyId,
   p.amount					AS Amount,
   p.status					AS Status,
   p.IsPaid					AS IsPaid,
   p.created_on				AS CreatedOn,
   ph.pharmacy_name			AS PharmacyName,
   ph.subscription_plan_id  AS SubscriptionPlanId,
   s.plan_name              AS SubscriptionPlanName
   INTO #Temp_invoice
   FROM payments p JOIN pharmacy_list ph  ON 
   P.pharmacy_id = ph.pharmacy_id
   JOIN sa_subscription_plan s ON 
   ph.subscription_plan_id= s.subscription_plan_id
   WHERE  ((ph.is_deleted != 1) AND 
		   ( (ph.pharmacy_name LIKE '%'+ISNULL(@SearchString, ph.pharmacy_name)+'%')
		    OR (s.plan_name  LIKE '%'+ISNULL(@SearchString, s.plan_name)+'%')
		   )
		   )

		 -- COUNT RECORD
		 SELECT @count= COUNT(*) FROM #Temp_invoice 

		 -- SELECT RECORD FROM TEMP TABLE
		 SELECT
		 PaymentId          AS PaymentId,
		 PharmacyId			AS PharmacyId,
		 Amount				AS Amount,
		 Status				AS Status,
		 IsPaid				AS IsPaid,
		 CreatedOn			AS CreatedOn,
		 PharmacyName		AS PharmacyName,
		 SubscriptionPlanId AS SubscriptionPlanId,
		 SubscriptionPlanName AS SubscriptionPlanName,
		 @count                           As Count
		 FROM #Temp_invoice
		  ORDER BY Amount desc
		 OFFSET  @PageSize * (@PageNumber - 1)   ROWS
         FETCH NEXT @PageSize ROWS ONLY	

		 -- drop temporary table
		 DROP TABLE #Temp_invoice
  END



GO
/****** Object:  StoredProcedure [dbo].[SP_save_update_wholesaler]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================
-- Author:      Sagar Sharma
-- Create date: 20-03-2018
-- Description: SP to INSERT or UPDATE the record in wholesaler table
-- =============================================

CREATE PROCEDURE [dbo].[SP_save_update_wholesaler]
	(
	@id					int,
	@pharmacyId			int,
	@name				nvarchar(90),
	@email				nvarchar(50),
	@isactive			bit,
	@created_by			int,	
	@address1			nvarchar(400),
	@address2			nvarchar(400),
	@country_id			int,
	@state_id			int,
	@city				nvarchar(150),
	@zipcode			nvarchar(10),
	@phone				nvarchar(20)
	)
 AS 
 BEGIN

 SET NOCOUNT ON;
	 IF(@id = 0)
	  BEGIN
		
		  INSERT INTO wholesaler(pharmacy_id, name, email, is_active, created_on, created_by, is_deleted)
		   VALUES
		  (@pharmacyId,@name, @email, @isactive, GETDATE(), @created_by,0) 
		
			DECLARE @wholesaler_id int;
			set  @wholesaler_id = (SELECT @@IDENTITY);

			INSERT into address_master(wholesaler_id, address_line1, address_line2, country_id, state_id,
			city, zipcode, phone, created_on, created_by, is_deleted)
			VALUES 
			(@wholesaler_id, @address1, @address2, @country_id, @state_id, @city, @zipcode, @phone, GETDATE(), @created_by,0)
			
	   END 
	ELSE 
		BEGIN
			UPDATE wholesaler SET 
			pharmacy_id=@pharmacyId, name=@name, email=@email, is_active=@isactive, updated_on=GETDATE(), updated_by=@created_by where wholesaler_id = @id

			UPDATE address_master SET 
			address_line1=@address1,address_line2=@address2, country_id=@country_id, state_id=@state_id,
			city=@city, zipcode=@zipcode, phone=@phone, updated_on=GETDATE(),updated_by=@created_by where wholesaler_id = @id
	END

	SET NOCOUNT OFF;
END;




GO
/****** Object:  StoredProcedure [dbo].[SP_savemessage]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author: Sagar Sharma     
-- Create date: 11-05-2018
-- Description: SP to save the message to message board.
-- =============================================

CREATE PROC [dbo].[SP_savemessage]
	@from_ph_id			INT,
	@to_ph_id			INT,
	@message			NVARCHAR(3000),
	@created_by			INT


	AS
   BEGIN
   
   INSERT INTO ph_messageboard (from_ph_id,to_ph_id,message,created_by,created_on,is_deleted,status)
		VALUES(@from_ph_id,@to_ph_id,@message,@created_by, GETDATE(),0,'unread'); 
   
  END




GO
/****** Object:  StoredProcedure [dbo].[SP_search_list_saPharmacy]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Priyanka Chandak
-- Modified by: Sagar Sharma on 06-03-2018
-- Create date: 27-02-2018
-- Description: SP to LIST or SEARCH from sa_pharmacy table
-- =============================================

--EXEC SP_search_list_saPharmacy ''
CREATE PROCEDURE [dbo].[SP_search_list_saPharmacy]
	(
	@search_string nvarchar(50)
	)
	  AS 
     
	     IF(@search_string='')
		  BEGIN
		    Select
			 p.pharmacy_id,
			 p.pharmacy_name		,	--AS PharmacyName,
			 p.pharmacy_owner_id	,	--AS PharmacyOwnerId,
			 p.pharmacy_logo		,	--AS PharmacyLogo	,
			 p.registrationdate		,	--AS Registrationdate,	
			 p.subscription_status	,	--AS SubscriptionStatus,
			 p.contact_no			,	--
			 p.mobile_no			,	--AS MobileNo,
			 p.created_by			,
			 p.created_on			,
			 p.updated_on			,
			 p.updated_by,
			 p.is_deleted,
			 p.deleted_on,
			 p.deleted_by,
			 a.superadmin_address_id,	--
			 a.address_line_1		,	--AS AddressLine1,
			 a.address_line_2		,	--AS AddressLine2,
			 a.country_id			,	--AS CountryId,
			 a.state_id				,	--AS StateId,
			 a.city_id				,	--AS CityId,
			 a.zipcode					--AS Zipcode 
			from sa_pharmacy AS p INNER JOIN sa_superAdmin_sddress AS a ON
			p.pharmacy_id=a.pharmacy_id
			WHERE p.deleted_by = null OR p.deleted_by='' OR p.is_deleted = 0
			END
	     ELSE
		  BEGIN
	        Select
			 p.pharmacy_id,
			 p.pharmacy_name		,	--AS PharmacyName,
			 p.pharmacy_owner_id	,	--AS PharmacyOwnerId,
			 p.pharmacy_logo		,	--AS PharmacyLogo	,
			 p.registrationdate		,	--AS Registrationdate,	
			 p.subscription_status	,	--AS SubscriptionStatus,
			 p.contact_no			,	--AS ContactNo,
			 p.mobile_no			,
			 p.created_by			,
			 p.created_on			,
			 p.updated_on			,
			 p.updated_by,
			 p.is_deleted,
			 p.deleted_on,
			 p.deleted_by,	--AS MobileNo,
			 a.superadmin_address_id,	--
			 a.address_line_1		,	--AS AddressLine1,
			 a.address_line_2		,	--AS AddressLine2,
			 a.country_id			,	--AS CountryId,
			 a.state_id				,	--AS StateId,
			 a.city_id				,	--AS CityId,
			 a.zipcode					--AS Zipcode 
			  from sa_pharmacy AS p INNER JOIN sa_superAdmin_sddress AS a ON
			p.pharmacy_id=a.pharmacy_id
			WHERE pharmacy_name like '%'+@search_string+'%' AND (p.deleted_by = null OR p.deleted_by='' OR p.is_deleted = 0)
          END


		




GO
/****** Object:  StoredProcedure [dbo].[SP_search_list_saPharmacyOwner]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
 -- =============================================
-- Author:      Priyanka Chandak
-- Create date: 27-02-2018
-- Description: SP to LIST or SEARCH from sa_pharmacy_owner table
-- =============================================

	
	 CREATE PROCEDURE [dbo].[SP_search_list_saPharmacyOwner]
	(
	@search_string nvarchar(50)
	)
	  AS 
      BEGIN
	     IF(@search_string='')
		    Select * from sa_pharmacy_owner AS P INNER JOIN sa_superAdmin_sddress AS A ON
			p.pharmacy_owner_id=A.pharmacy_owner_id  
			 WHERE P.deleted_by = null OR P.deleted_by='' OR P.is_deleted=0
	     ELSE
	        Select * from sa_pharmacy_owner AS P INNER JOIN sa_superAdmin_sddress AS A ON 
            P.pharmacy_owner_id=A.pharmacy_owner_id
			WHERE P.first_name like '%'+@search_string+'%' AND 
            (P.deleted_by = null OR P.deleted_by='' OR P.is_deleted=0)
      END




GO
/****** Object:  StoredProcedure [dbo].[SP_SearchPosting]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================      
      
-- Create date: 25-02-2019      
-- Created By: Humera Sheikh    
-- Description: SP to show Posted Items    
-- EXEC SP_SearchPosting 1417,40,1,'alp'      
-- =============================================      
      
      
      
CREATE PROC [dbo].[SP_SearchPosting]      
      
	  @pharmacy_id INT,      
	  @PageSize  INT,      
	  @PageNumber    INT,        
	  @SearchString  NVARCHAR(100)=null      
      
  AS      
      
   BEGIN      
	   DECLARE @count INT;	        	 
	        
	   SELECT     
		   mp_postitem_id AS MpPostitemId,    
		   drug_name AS DrugName,    
		   ndc_code AS NdcCode,    
		   generic_code AS GenericCode,    
		   pack_size AS PackSize,    
		   strength AS Strength,    
		   base_price AS BasePrice,    
		   sales_price AS SalesPrice,    
		   lot_number AS LotNumber,    
		   exipry_date AS ExipryDate,    
		   pl.pharmacy_name AS PharmacyName,    
		   pl.Email AS Email,    
		   pl.pharmacy_id AS PharmacyId,    
		   pl.PlanExpireDT AS ExpiryDate,    
		   networktyp.mp_network_type_id AS MpNetworkTypeId,    
		   COUNT(1) OVER () AS Count      
	   FROM [dbo].[mp_post_items] Postitem     	    
		   INNER JOIN pharmacy_list pl on Postitem.pharmacy_id = pl.pharmacy_id    
		   INNER JOIN mp_network_type networktyp on Postitem.mp_network_type_id = networktyp.mp_network_type_id
		   INNER JOIN sister_pharmacy_mapping ss_ph ON ss_ph.sister_pharmacy_id = Postitem.pharmacy_id AND ss_ph.parent_pharmacy_id = @pharmacy_id AND ISNULL(ss_ph.is_deleted,0) = 0
	   WHERE (Postitem.pharmacy_id <> @pharmacy_id)     
		   AND (ISNULL(Postitem.is_deleted,0) = 0)     		   
	   ORDER BY  mp_postitem_id DESC    
	   OFFSET  @PageSize * (@PageNumber - 1)   ROWS      
	   FETCH NEXT IIF(@PageSize = 0, 100000, @PageSize) ROWS ONLY      
        
   END    

GO
/****** Object:  StoredProcedure [dbo].[SP_SearchPosting_bk03052019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================        
        
-- Create date: 25-02-2019        
-- Created By: Humera Sheikh      
-- Description: SP to show Posted Items      
-- EXEC SP_SearchPosting 13,0,1,''       
-- =============================================        
        
        
        
CREATE PROC [dbo].[SP_SearchPosting_bk03052019]        
        
  @pharmacy_id int,        
  @PageSize  int,        
  @PageNumber    int,          
  @SearchString  nvarchar(100)=null        
        
  AS        
        
   BEGIN        
   DECLARE @count int;       
   with SisterPharmacyMapping AS (      
   SELECT       
   parent_pharmacy_id AS ParentPharmacyId,      
   sister_pharmacy_id AS SisterPharmacyId       
   FROM [sister_pharmacy_mapping] SisPharmacy      
   WHERE (parent_pharmacy_id = @pharmacy_id AND is_deleted = 0)      
   )       
   SELECT       
   mp_postitem_id AS MpPostitemId,      
   drug_name AS DrugName,      
   ndc_code AS NdcCode,      
   generic_code AS GenericCode,      
   pack_size AS PackSize,      
   strength AS Strength,      
   base_price AS BasePrice,      
   sales_price AS SalesPrice,      
   lot_number AS LotNumber,      
   exipry_date AS ExipryDate,      
   pl.pharmacy_name AS PharmacyName,      
   pl.Email AS Email,      
   pl.pharmacy_id AS PharmacyId,      
   pl.PlanExpireDT AS ExpiryDate,      
   networktyp.mp_network_type_id AS MpNetworkTypeId,      
   COUNT(1) OVER () AS Count        
   FROM [dbo].[mp_post_items] Postitem         
   inner join pharmacy_list pl on Postitem.pharmacy_id = pl.pharmacy_id      
   inner join mp_network_type networktyp on Postitem.mp_network_type_id = networktyp.mp_network_type_id      
   WHERE (Postitem.pharmacy_id <> @pharmacy_id)       
   AND (ISNULL(Postitem.is_deleted,0) = 0)       
   AND (Postitem.pharmacy_id IN (select SisterPharmacyMapping.SisterPharmacyId from SisterPharmacyMapping))      
   ORDER BY  mp_postitem_id DESC      
   OFFSET  @PageSize * (@PageNumber - 1)   ROWS        
   FETCH NEXT IIF(@PageSize = 0, 100000, @PageSize) ROWS ONLY        
          
   END      
GO
/****** Object:  StoredProcedure [dbo].[SP_send_broadcast_message]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================

-- Author: Sagar Sharma     

-- Create date: 18-05-2018

-- Description: SP to send/start the broadcast message.

-- =============================================



CREATE PROC [dbo].[SP_send_broadcast_message]

	@broadcast_title_id			INT,

	@broadcast_title			NVARCHAR(1500),

	@broadcast_message			NVARCHAR(2500),

	@pharmacy_id				INT





	AS

   BEGIN

		DECLARE @broadcast_title_id_Identity INT

		DECLARE @pharmacyCount INT

		IF(@broadcast_title_id=0)

			BEGIN

				INSERT INTO broadcast_message_title_master(broadcast_message_title, created_by, created_on, is_deleted)

				VALUES(@broadcast_title, @pharmacy_id, GETDATE(), 0);
				Select @broadcast_title_id_Identity  =	 @@Identity;

				INSERT INTO broadcast_message(broadcast_message_title_masterid, pharmacy_id, message, created_by, created_on, is_deleted)

				VALUES(@broadcast_title_id_Identity, @pharmacy_id, @broadcast_message, @pharmacy_id, GETDATE(), 0);

		



		/*here we are adding details to broadcast notification table for displaying the notification in dashboard */		

		INSERT INTO broadcast_notification(broadcast_message_title_masterid, pharmacy_id, is_read, message, created_by, created_on)

		(SELECT @broadcast_title_id_Identity, sister_pharmacy_id, 0, @broadcast_message, @pharmacy_id, GETDATE()  

			FROM sister_pharmacy_mapping WHERE is_deleted = 0 AND parent_pharmacy_id = @pharmacy_id)
		

			END





		ELSE

			BEGIN

				INSERT INTO broadcast_message(broadcast_message_title_masterid, pharmacy_id, message, created_by, created_on, is_deleted)

				VALUES(@broadcast_title_id, @pharmacy_id, @broadcast_message, @pharmacy_id, GETDATE(), 0);

		--Select @broadcast_title_id_Identity  =	 @@Identity;

		/*here we are adding details to broadcast notification table for displaying the notification in dashboard */		

		INSERT INTO broadcast_notification(broadcast_message_title_masterid, pharmacy_id, is_read, message, created_by, created_on)

		(SELECT @broadcast_title_id, sister_pharmacy_id, 0, @broadcast_message, @pharmacy_id, GETDATE()  

			FROM sister_pharmacy_mapping WHERE is_deleted = 0 AND parent_pharmacy_id = @pharmacy_id)

		END

  END






GO
/****** Object:  StoredProcedure [dbo].[sp_sisterpharmacylist]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
--sp_sisterpharmacylist 11,10,1,'f'

CREATE PROC [dbo].[sp_sisterpharmacylist]
  @pharmacy_id  int,
  @PageSize		int,
  @PageNumber    int,
  @SearchString  nvarchar(100)=null
AS 

BEGIN
 DECLARE @count int;  
   SELECT * INTO #Temp_pharmacy FROM sister_pharmacy_mapping
   WHERE parent_pharmacy_id=@pharmacy_id and is_deleted!=1


   SELECT A.sister_pharmacy_mapping_id    SisterPharmacyMappingId,  
   B.pharmacy_name						  PharmacyName,
   C.first_name +' '+	C.last_name		  OwnerName   	
   INTO #Temp_sispharmacydata						 
   FROM pharmacy_list B JOIN #Temp_pharmacy A 
   ON A.sister_pharmacy_id= B.pharmacy_id
   JOIN [dbo].[sa_pharmacy_owner] C
   ON B.pharmacy_owner_id=C.pharmacy_owner_id
   Where B.pharmacy_name LIKE '%' + ISNULL(@SearchString,B.pharmacy_name) + '%'

    SELECT @count= COUNT(*) FROM #Temp_sispharmacydata 

	SELECT 
	SisterPharmacyMappingId       SisterPharmacyMappingId,
	PharmacyName				  PharmacyName,
	OwnerName   				  OwnerName,
	@count						  Count
	FROM #Temp_sispharmacydata
	ORDER BY SisterPharmacyMappingId desc
	OFFSET  @PageSize * (@PageNumber - 1)   ROWS
    FETCH NEXT @PageSize ROWS ONLY	

  DROP TABLE #Temp_pharmacy
  drop table #Temp_sispharmacydata

END






GO
/****** Object:  StoredProcedure [dbo].[SP_softdelete_medicine]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 20-03-2018
-- Description: SP to SOFT DELETE medicine
-- Modified by : Sagar Sharma on 02-04-2018
-- =============================================


CREATE PROCEDURE [dbo].[SP_softdelete_medicine](
	@id int,
	@deleted_by int
)
  AS 
 
  IF (@id IS NOT NULL)
	BEGIN
	 UPDATE [dbo].[medicine] SET deleted_by = @deleted_by,deleted_on=GETDATE(), is_deleted=1 WHERE medicine_id =@id

	return '1'
    END

	--EXEC [dbo].[SP_softdelete_medicine] 9,1



GO
/****** Object:  StoredProcedure [dbo].[SP_softdelete_order]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author:      Sagar Sharma
-- Create date: 02-04-2018
-- Description: SP to SOFT DELETE Order
-- =============================================

CREATE PROCEDURE [dbo].[SP_softdelete_order](
	@id int,
	@deleted_by int
)
  AS 
 
  IF (@id IS NOT NULL)
	BEGIN
	 UPDATE orders SET deleted_by = @deleted_by, deleted_on = GETDATE(), is_deleted = 1 WHERE order_id = @id

	return '1'

    END



GO
/****** Object:  StoredProcedure [dbo].[SP_softdelete_pharmacyUser]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 20-03-2018
-- Description: SP to SOFT DELETE pharmacy user
-- =============================================


CREATE PROCEDURE [dbo].[SP_softdelete_pharmacyUser](
	@id int,
	@deleted_by int
)
  AS 
 
  IF (@id IS NOT NULL)
	BEGIN
	 UPDATE [dbo].[pharmacy_users] SET deleted_by = @deleted_by,deleted_on=GETDATE(), is_deleted=1 WHERE pharmacy_user_id =@id

	return '1'
    END

	EXEC [dbo].[SP_softdelete_pharmacyUser] 9,1



GO
/****** Object:  StoredProcedure [dbo].[SP_softdelete_pharmacyUserRole]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[SP_softdelete_pharmacyUserRole](
	@id int,
	@deleted_by int
)
  AS 
 
  IF (@id IS NOT NULL)
	BEGIN
	 UPDATE pharmacy_users_roles_assignment SET deleted_by = @deleted_by,deleted_on=GETDATE(), is_deleted=1 WHERE pharmacy_user_id =@id
	 UPDATE  [dbo].[pharmacy_users] SET username=null,password=null where pharmacy_user_id=@id
	return '1'
    END



GO
/****** Object:  StoredProcedure [dbo].[SP_softdelete_posteditems]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Create date: 04-05-2018
-- Description: SP to SOFT DELETE posted items
-- =============================================

CREATE PROCEDURE [dbo].[SP_softdelete_posteditems](
    @PharmacyId int,
	@id int,
	@deleted_by int
)
  AS 
 
  IF (@id IS NOT NULL)
	BEGIN
	 UPDATE mp_post_items SET deleted_by = @deleted_by, deleted_on = GETDATE(), is_deleted = 1 
	 WHERE mp_postitem_id = @id AND pharmacy_id=@PharmacyId

	return '1'

    END
	--select * from mp_post_items where is_deleted IS NULL



GO
/****** Object:  StoredProcedure [dbo].[SP_softdelete_sister_pharmacy_mapping]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================
-- Author:      Sagar Sharma
-- Create date: 27-03-2018
-- Description: SP to SOFT DELETE Sister Pharmacy Mapping.
-- =============================================

CREATE PROCEDURE [dbo].[SP_softdelete_sister_pharmacy_mapping](
	@mapping_id int,
	@deleted_by int
)
  AS 
 
  IF (@mapping_id IS NOT NULL)
	BEGIN
	 UPDATE sister_pharmacy_mapping SET deleted_by = @deleted_by,deleted_on=GETDATE(), is_deleted=1 WHERE sister_pharmacy_mapping_id =@mapping_id

	return '1'
    END



GO
/****** Object:  StoredProcedure [dbo].[SP_softdelete_wholesaler]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Sagar Sharma
-- Create date: 20-03-2018
-- Description: SP to SOFT DELETE Wholesaler
-- =============================================

CREATE PROCEDURE [dbo].[SP_softdelete_wholesaler](
	@id int,
	@deleted_by int
)
  AS 
 
  IF (@id IS NOT NULL)
	BEGIN
	 UPDATE wholesaler SET deleted_by = @deleted_by,deleted_on=GETDATE(), is_deleted=1 WHERE wholesaler_id =@id

	 UPDATE edi_server_configuration SET deleted_by = @deleted_by,deleted_on=GETDATE(), is_deleted=1 WHERE wholeseller_id =@id

	return '1'
    END



GO
/****** Object:  StoredProcedure [dbo].[SP_softdeletetransferorder]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

--==============================================

-- Created by: Sagar Sharma

-- Create date: 02-AUG-2018

-- Description: SP to soft delete the transfer order by seller pharmacy.

-- =============================================


CREATE PROCEDURE [dbo].[SP_softdeletetransferorder]

(  
	@transferMgmtId         INTEGER
)  

AS  

	BEGIN  

		 UPDATE transfer_management set 
				is_deletd = 1,
				deleted_on = GETDATE()
		 WHERE transfer_mgmt_id	= @transferMgmtId

	END  











GO
/****** Object:  StoredProcedure [dbo].[SP_statusclassification]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
--EXEC SP_statusclassification 12

CREATE PROC [dbo].[SP_statusclassification]
  @pharmacy_id INT
    
	AS
   BEGIN
   DECLARE @loc_pharmacy_id INT
   SET @loc_pharmacy_id = @pharmacy_id

   DECLARE @currentonhand MONEY
   DECLARE @overstock MONEY
   DECLARE @surplus MONEY
   DECLARE @new MONEY
   DECLARE @recurring MONEY
   DECLARE @sporadic MONEY
   DECLARE @newpercentage MONEY
   DECLARE @recurringpercentage MONEY
   DECLARE @sporadicpercentage MONEY

   	
    CREATE TABLE #Temp_statusclassification(
		 PharmacyId INT,
		 WholesalerId INT, 
		 MedicineName NVARCHAR(500),
		 NDC BIGINT, 
		 QuantityOnHand INT, 
		 OptimalQuantity INT,
		 ExpirtyDate DATE,
		 Strength NVARCHAR(1000),
		 Price MONEY,
		 Count  INT,
		
	)

	SELECT @currentonhand = SUM(ISNULL(price,0 )* ISNULL(pack_size,0) ) from inventory WHERE (
		(pharmacy_id = @loc_pharmacy_id) AND (is_deleted = 0) AND (pack_size > 0)
	)

	INSERT INTO #Temp_statusclassification
    EXEC SP_OverSupply @loc_pharmacy_id,0,0,''
	
	SELECT @overstock = SUM(ISNULL(Price,0 )* ISNULL(QuantityOnHand,0) ) from #Temp_statusclassification


   SELECT @surplus = @currentonhand - @overstock;
   
   
    /*New Inventory: Any inventory purchased within  0-30 days with no prior history
		1. Find inventory those not sold in 30 days.
		2. Find inventory those does not have record in rx30 register
		3. New Inventory = sum of 1 and 2 
	*/	
	
	SELECT 
		@new = SUM(ISNULL(inv.price,0 )* ISNULL(inv.pack_size,0) )			
	FROM inventory inv
		INNER JOIN RX30_inventory inv_rx30 ON inv_rx30.[ndc] = inv.[ndc] 
	WHERE ((inv_rx30.pharmacy_id = @loc_pharmacy_id) AND  
		(inv_rx30.created_on < DATEADD(DAY, -30, GETDATE()) )
		AND 
		(ISNULL(inv.is_deleted,0) = 0) AND (ISNULL(inv.pack_size,0) > 0)
		)		
	
	
	SELECT 
		@new = (ISNULL(@new,0) + SUM(ISNULL(inv.price,0 )* ISNULL(inv.pack_size,0)))			
	FROM inventory inv
	
	WHERE (
		(inv.ndc  not in (SELECT inv_rx30.ndc FROM RX30_inventory inv_rx30 WHERE  inv_rx30.ndc IS NOT NULL)) and
	(inv.pharmacy_id = @loc_pharmacy_id) AND  		
		(ISNULL(inv.is_deleted,0) = 0) AND (ISNULL(inv.pack_size,0) > 0)
		)

	/*------------------------------------------------------------------------------------------------------*/
	
    SELECT @newpercentage = (@new/@currentonhand) *100
	
	/*Recurring Inventory : Any inventory with prior  purchase history  and usage between 0-180 days */

	SELECT 
		@recurring = SUM(ISNULL(inv.price,0 )* ISNULL(inv.pack_size,0) )	
	FROM inventory  inv
	--INNER JOIN RX30_inventory inv_rx30 ON inv_rx30.[ndc] = inv.[ndc] 
	WHERE (
		(inv.pharmacy_id = @loc_pharmacy_id) AND  		
		--((inv_rx30.created_on < DATEADD(DAY, -180, GETDATE())) AND (inv_rx30.created_on > DATEADD(DAY, -30, GETDATE())) ) AND 
		(inv.created_on BETWEEN 
										(DATEADD(DAY, -180, GETDATE())) AND  (DATEADD(DAY, -30, GETDATE()))
									
		) AND
		(ISNULL(inv.is_deleted,0) = 0) AND (ISNULL(inv.pack_size,0) > 0)
	)
					
	/*------------------------------------------------------------------------------------------------------*/

	SELECT @recurringpercentage = (@recurring/@currentonhand) *100

	/* Sporadic Inventory: Inventory with prior purchase history, however no usage or reordering within days 181 +*/

	SELECT 
		@sporadic = SUM(ISNULL(inv.price,0 )* ISNULL(inv.pack_size,0) )	
		
	FROM inventory inv
		--INNER JOIN RX30_inventory inv_rx30 ON inv_rx30.[ndc] = inv.[ndc]    
	WHERE ((inv.pharmacy_id = @loc_pharmacy_id) AND  
		(inv.created_on < DATEADD(DAY, -182, GETDATE()) )
		AND 
		(ISNULL(inv.is_deleted,0) = 0) AND (ISNULL(inv.pack_size,0) > 0)
		)
	--SELECT @sporadic = SUM(price) FROM inventory 
	--WHERE pharmacy_id = @pharmacy_id AND  
	--	(created_on >= DATEADD(DAY, -181, GETDATE()))

	/*------------------------------------------------------------------------------------------------------*/

	SELECT @sporadicpercentage = (@sporadic/@currentonhand) *100

	SELECT 	 
		ISNULL(@currentonhand,0)				AS CurrentOnHand,
		 ISNULL(@overstock,0)					AS OverStock,
		 ISNULL(@surplus,0)					AS Surplus,
		 ISNULL(@newpercentage,0)				AS New, 
		 ISNULL(@recurringpercentage,0)		AS Recurring,
		 ISNULL(@sporadicpercentage,0)		AS Sporadic	  
	 
	 DROP TABLE #Temp_statusclassification

  END




GO
/****** Object:  StoredProcedure [dbo].[SP_statusclassification_bk_06102019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
--EXEC SP_statusclassification 12

CREATE PROC [dbo].[SP_statusclassification_bk_06102019]
  @pharmacy_id INT
    
	AS
   BEGIN
   DECLARE @currentonhand MONEY
   DECLARE @overstock MONEY
   DECLARE @surplus MONEY
   DECLARE @new MONEY
   DECLARE @recurring MONEY
   DECLARE @sporadic MONEY
   DECLARE @newpercentage MONEY
   DECLARE @recurringpercentage MONEY
   DECLARE @sporadicpercentage MONEY

   	
    CREATE TABLE #Temp_statusclassification(
		 PharmacyId INT,
		 WholesalerId INT, 
		 MedicineName NVARCHAR(500),
		 NDC BIGINT, 
		 QuantityOnHand INT, 
		 OptimalQuantity INT,
		 ExpirtyDate DATE,
		 Strength NVARCHAR(1000),
		 Price MONEY,
		 Count  INT,
		
	)

	SELECT @currentonhand = SUM(ISNULL(price,0 )* ISNULL(pack_size,0) ) from inventory WHERE (
		(pharmacy_id = @pharmacy_id) AND (is_deleted = 0) AND (pack_size > 0)
	)

	INSERT INTO #Temp_statusclassification
    EXEC SP_OverSupply @pharmacy_id,0,0,''
	
	SELECT @overstock = SUM(ISNULL(Price,0 )* ISNULL(QuantityOnHand,0) ) from #Temp_statusclassification


   SELECT @surplus = @currentonhand - @overstock;
   
   
    /*New Inventory: Any inventory purchased within  0-30 days with no prior history
		1. Find inventory those not sold in 30 days.
		2. Find inventory those does not have record in rx30 register
		3. New Inventory = sum of 1 and 2 
	*/	
	
	SELECT 
		@new = SUM(ISNULL(inv.price,0 )* ISNULL(inv.pack_size,0) )			
	FROM inventory inv
		INNER JOIN RX30_inventory inv_rx30 ON inv_rx30.[ndc] = inv.[ndc] 
	WHERE ((inv_rx30.pharmacy_id = @pharmacy_id) AND  
		(inv_rx30.created_on < DATEADD(DAY, -30, GETDATE()) )
		AND 
		(ISNULL(inv.is_deleted,0) = 0) AND (ISNULL(inv.pack_size,0) > 0)
		)		
	
	
	SELECT 
		@new = (ISNULL(@new,0) + SUM(ISNULL(inv.price,0 )* ISNULL(inv.pack_size,0)))			
	FROM inventory inv
	
	WHERE (
		(inv.ndc  not in (SELECT inv_rx30.ndc FROM RX30_inventory inv_rx30 WHERE  inv_rx30.ndc IS NOT NULL)) and
	(inv.pharmacy_id = @pharmacy_id) AND  		
		(ISNULL(inv.is_deleted,0) = 0) AND (ISNULL(inv.pack_size,0) > 0)
		)

	/*------------------------------------------------------------------------------------------------------*/
	
    SELECT @newpercentage = (@new/@currentonhand) *100
	
	/*Recurring Inventory : Any inventory with prior  purchase history  and usage between 0-180 days */

	SELECT 
		@recurring = SUM(ISNULL(inv.price,0 )* ISNULL(inv.pack_size,0) )	
	FROM inventory  inv
	--INNER JOIN RX30_inventory inv_rx30 ON inv_rx30.[ndc] = inv.[ndc] 
	WHERE (
		(inv.pharmacy_id = @pharmacy_id) AND  		
		--((inv_rx30.created_on < DATEADD(DAY, -180, GETDATE())) AND (inv_rx30.created_on > DATEADD(DAY, -30, GETDATE())) ) AND 
		(inv.created_on BETWEEN 
										(DATEADD(DAY, -180, GETDATE())) AND  (DATEADD(DAY, -30, GETDATE()))
									
		) AND
		(ISNULL(inv.is_deleted,0) = 0) AND (ISNULL(inv.pack_size,0) > 0)
	)
					
	/*------------------------------------------------------------------------------------------------------*/

	SELECT @recurringpercentage = (@recurring/@currentonhand) *100

	/* Sporadic Inventory: Inventory with prior purchase history, however no usage or reordering within days 181 +*/

	SELECT 
		@sporadic = SUM(ISNULL(inv.price,0 )* ISNULL(inv.pack_size,0) )	
		
	FROM inventory inv
		--INNER JOIN RX30_inventory inv_rx30 ON inv_rx30.[ndc] = inv.[ndc]    
	WHERE ((inv.pharmacy_id = @pharmacy_id) AND  
		(inv.created_on < DATEADD(DAY, -182, GETDATE()) )
		AND 
		(ISNULL(inv.is_deleted,0) = 0) AND (ISNULL(inv.pack_size,0) > 0)
		)
	--SELECT @sporadic = SUM(price) FROM inventory 
	--WHERE pharmacy_id = @pharmacy_id AND  
	--	(created_on >= DATEADD(DAY, -181, GETDATE()))

	/*------------------------------------------------------------------------------------------------------*/

	SELECT @sporadicpercentage = (@sporadic/@currentonhand) *100

	SELECT 	 
		ISNULL(@currentonhand,0)				AS CurrentOnHand,
		 ISNULL(@overstock,0)					AS OverStock,
		 ISNULL(@surplus,0)					AS Surplus,
		 ISNULL(@newpercentage,0)				AS New, 
		 ISNULL(@recurringpercentage,0)		AS Recurring,
		 ISNULL(@sporadicpercentage,0)		AS Sporadic	  
	 
	 DROP TABLE #Temp_statusclassification

  END




GO
/****** Object:  StoredProcedure [dbo].[SP_subscription_module_assignment]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROC [dbo].[SP_subscription_module_assignment]
		@module_id				INT,
		@pharmacy_id			INT,
		@subscription_plan_id	INT,
		@pharmacy_module_id		INT,
		@is_hide				BIT
		
	AS
	  BEGIN

		IF(@module_id =0)
		BEGIN
		INSERT INTO subscription_module_assignment
		(subscription_plan_id,pharmacy_module_id,created_on,created_by,is_deleted,is_hide)
		VALUES
		(@subscription_plan_id,@pharmacy_module_id,GETDATE(),@pharmacy_id,0,@is_hide)
		END

	  ELSE

		BEGIN

		UPDATE subscription_module_assignment SET	
		subscription_plan_id=@subscription_plan_id,
		pharmacy_module_id=@pharmacy_module_id,
		updated_on=GETDATE(),
		updated_by=@pharmacy_id,
		is_hide=@is_hide
		WHERE subscription_module_assignment_id=@module_id

		END
	END

--select * from subscription_module_assignment
--SP_subscription_module_assignment 15,1417,15,5,true






GO
/****** Object:  StoredProcedure [dbo].[Sp_subscriptionmodules]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================  
-- Create date: 14-03-2019  
-- Description: SP to Get Subscription Modules 
-- By Humera Sheikh  
-- EXEC SP_SubscriptionModules 9 ,101 
-- =============================================  
CREATE PROC [dbo].[Sp_subscriptionmodules] 
	@subscriptionPlanId INT, 
	@roleId             INT 
AS 
  BEGIN 
	DECLARE @PharmacyStaff      INT
	SET @PharmacyStaff = 102

      IF ( @roleId = @PharmacyStaff ) 
        BEGIN 
            SELECT pr.pharmacy_role_module_assignment_id AS 
                   SubscriptionModuleAssignmentId, 
                   pr.role_id                            AS RoleId, 
                   pr.module_id                          AS PharmacyModuleId, 
                   pr.is_deletd                          AS IsDeletd, 
                   pm.module_name                        AS ModuleName 
            FROM   [dbo].[pharmacy_role_module_assignment] pr 
                   INNER JOIN [dbo].[pharmacy_module_master] pm 
                           ON pr.module_id = pm.pharmacy_module_id 
            WHERE  @roleId = role_id 
                   AND pr.is_deletd = 0 
        END 
      ELSE 
        BEGIN 
            SELECT sm.subscription_module_assignment_id AS 
                   SubscriptionModuleAssignmentId, 
                   sm.subscription_plan_id              AS SubscriptionPlanId, 
                   sm.pharmacy_module_id                AS PharmacyModuleId, 
                   pm.module_name                       AS ModuleName 
            FROM   [dbo].[subscription_module_assignment] sm 
                   INNER JOIN [dbo].[pharmacy_module_master] pm 
                           ON sm.pharmacy_module_id = pm.pharmacy_module_id 
            WHERE  subscription_plan_id = @subscriptionPlanId 
                   AND sm.is_hide = 1 
        END 
  END 


GO
/****** Object:  StoredProcedure [dbo].[SP_superadminlogin]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE PROCEDURE [dbo].[SP_superadminlogin]
(  
	@username				NVARCHAR(20),
	@password			NVARCHAR(20)
)  
AS  
BEGIN 
	SELECT *
  FROM superadmin_login
  where password COLLATE Latin1_General_CS_AS  = @password

	
END



GO
/****** Object:  StoredProcedure [dbo].[SP_Surplus_Inventory_rowdata]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 10-04-2018
-- Description: SP to show surplus Summary returns
--EXEC SP_Surplus_Inventory_rowdata 1417
-- =============================================
CREATE PROC [dbo].[SP_Surplus_Inventory_rowdata]
	@pharmacy_id INT    
	AS
   BEGIN
  
  
   /*
   3) Remaining Surplus Inventory= inventory remaining after all possible returns to wholesaler/possible transfers to other stores. 
		a. Basically this is going to be any inventory with less than 1 month expiration, expired inventory, or 
		b. inventory that has no usage by any other store - This condition need to discussed.

   */
   
	DECLARE @expired_month INT
	SELECT @expired_month = [expiry_month] FROM [Inv_Exp_Config]

	DECLARE @expires_month_before INT = @expired_month -1
	
	CREATE TABLE #Temp_Surplus(		
		inventory_id INT,
		pharmacy_id INT,
		wholesaler_id INT,
		ndc				BIGINT,
		drug_name NVARCHAR(500),
		price  DECIMAL(12,2),
		pack_size DECIMAL(12,2),		
		OptimalQuantity DECIMAL(10,2),
		created_on DATETIME,
		expire_date  DATETIME				
	)

		INSERT INTO  #Temp_Surplus(inventory_id, pharmacy_id, wholesaler_id, ndc, drug_name, price, pack_size, OptimalQuantity, created_on, expire_date)	
			SELECT inv.inventory_id
				, inv.pharmacy_id
				,inv.wholesaler_id
				,inv.ndc			
				, inv.drug_name
				, inv.price
				,inv.pack_size
				/*, dbo.FN_calculate_optimum_qty(ndc,@pharmacy_id)	AS OptimalQuantity*/
				,0
				,inv.created_on
				,EOMONTH(DATEADD(month, @expired_month ,inv.created_on)) as expire_date 
			FROM inventory inv
			WHERE (
				(inv.pharmacy_id=@pharmacy_id) AND 
				(ISNULL(inv.is_deleted,0)=0) AND
				(ISNULL(inv.pack_size,0) > 0) AND
				(
					((EOMONTH(DATEADD(month, @expires_month_before ,inv.created_on))) <= EOMONTH(GETDATE())) OR 
					((EOMONTH(DATEADD(month, @expired_month ,inv.created_on))) <= EOMONTH(GETDATE()))
				)
			)		
	
			
	/*This logic added to avoid calculating Optimum quantity for duplicate ndc*/
	 CREATE TABLE #Temp_OQ(				
		NDC				BIGINT,		
		OptimalQuantity DECIMAL(10,2),
		NDC_Count       INT		
	)

	INSERT INTO #Temp_OQ(NDC,OptimalQuantity,NDC_Count)
		SELECT NDC,0,COUNT(NDC)
		FROM #Temp_Surplus
		GROUP BY NDC
	
	 /*Update Optimume quantity*/
	 UPDATE #Temp_OQ
		SET OptimalQuantity = dbo.FN_calculate_optimum_qty(NDC,@pharmacy_id)
	
	 UPDATE temp_S
		SET temp_S.OptimalQuantity = temp_OQ.OptimalQuantity
	 FROM #Temp_Surplus temp_S
	 INNER JOIN #Temp_OQ temp_OQ ON temp_OQ.NDC = temp_S.NDC	 		
	 
	 /*----------------------------------------------------*/

	SELECT * FROM #Temp_Surplus

	DROP TABLE #Temp_OQ	
	DROP TABLE #Temp_Surplus
	
  ----------------------------------------------------------------------------  	  
  END

  



  



GO
/****** Object:  StoredProcedure [dbo].[SP_surplus_obsolute]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 05-04-2018
-- Description: SP to for oversupply/surplus
--SP_surplus_oversupply 24,10,1,'',2
-- =============================================

CREATE PROC [dbo].[SP_surplus_obsolute]
   @pharmacy_id			int,
   @PageSize			int,
   @PageNumber			int,
   @SearchString		nvarchar(100)=null,
   @type				int
   
	AS
   BEGIN
   
	 IF(@type=1)
		 BEGIN
			 EXEC SP_inventory_overstock @pharmacy_id,@PageSize,@PageNumber,@SearchString
		 END
     ELSE IF(@type=2)
	     BEGIN 
			
			 /* This sp is obsolute
					 EXEC SP_surplus @pharmacy_id,@PageSize,@PageNumber,@SearchString
					 */

			CREATE TABLE #Temp_Remaining_Surplus_Inventory(		
				InventoryId INT,		
				PharmacyId INT,
				WholesalerId  INT,
				NDC			INT,
				MedicineName NVARCHAR(1000),		
				Price MONEY,
				QuantityOnHand DECIMAL(18,5),				
				OptimalQuantity DECIMAL(18,5),				
				created_on	DATETIME,
				expire_date	 DATETIME						
			) 

			INSERT INTO  #Temp_Remaining_Surplus_Inventory(InventoryId, PharmacyId,WholesalerId, NDC, MedicineName, price,QuantityOnHand, OptimalQuantity, created_on,expire_date)
				EXEC SP_Surplus_Inventory_Parent @pharmacy_id
			 
			 DECLARE @count int;
			 SELECT @count =  ISNULL(COUNT(*),0) FROM #Temp_Remaining_Surplus_Inventory	

			 SELECT		
				InventoryId,
				PharmacyId,
				WholesalerId,
				MedicineName,
				QuantityOnHand,
				OptimalQuantity,		
				NDC,
				@count AS Count,
				Price
			 FROM #Temp_Remaining_Surplus_Inventory 		
				WHERE PharmacyId=@pharmacy_id AND (MedicineName LIKE '%'+ISNULL(@SearchString,MedicineName)+'%')		
			 ORDER BY InventoryId 
			 OFFSET  @PageSize * (@PageNumber - 1)   ROWS
			 FETCH NEXT @PageSize ROWS ONLY	
			
			DROP TABLE #Temp_Remaining_Surplus_Inventory		
		 END  
 

  END


GO
/****** Object:  StoredProcedure [dbo].[SP_surplus_oversupply]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO



-- =============================================

-- Author:      Priyanka Chandak
-- Create date: 05-04-2018
-- Description: SP to for oversupply/surplus
-- exec SP_surplus_oversupply 11,200,1,'',1

-- =============================================


CREATE PROC [dbo].[SP_surplus_oversupply]
   @pharmacy_id			INT,
   @PageSize			INT,
   @PageNumber			INT,
   @SearchString		NVARCHAR(100)=null,
   @type				INT=1

   	AS
   BEGIN  
   
	DECLARE @count INT
	         
			 DECLARE @temp_pagesize INT
		     SET @temp_pagesize=0

			 CREATE TABLE #Temp_overstock
			 (
				  PharmacyId		INT,
				  WholesalerId		INT,
				  MedicineName		NVARCHAR(500),
				  NDC				BIGINT,
				  QuantityOnHand	DECIMAL(10,2),
				  OptimalQuantity	DECIMAL(10,2),
				  ExpirtyDate		DATETIME,
				  Price				DECIMAL(12,2),
				  Count				INT,
				  Strength          NVARCHAR(100),
				  priority			INT
			 )

			 -- Retrieveing  the data from SP_OverSupply SP

			 INSERT INTO #Temp_overstock(PharmacyId, WholesalerId, MedicineName, NDC, QuantityOnHand, OptimalQuantity, ExpirtyDate,Strength, Price, Count)
				EXEC SP_OverSupply @pharmacy_id,@temp_pagesize,@PageNumber,@SearchString

			 UPDATE temp_os			 
				SET priority = CASE
									WHEN (QuantityOnHand >= (3 * OptimalQuantity)) THEN 1  /*High*/
									WHEN (
											((QuantityOnHand >= (2 * OptimalQuantity)) AND 
											(QuantityOnHand < (3 * OptimalQuantity)))
											) THEN 2  /*Medium*/
									WHEN (
										   ((QuantityOnHand = OptimalQuantity) OR 
										   (QuantityOnHand < (2 * OptimalQuantity)))
										   ) THEN 3  /*Low*/
								END	
			 FROM #Temp_overstock temp_os


			 SELECT @count = ISNULL(COUNT(*),0) FROM #Temp_overstock 
				  WHERE  priority = @type
			
			SELECT
				 MedicineName		AS MedicineName,
				 NDC				AS NDC,
				 QuantityOnHand		AS QuantityOnHand,
				 OptimalQuantity    AS OptimalQuantity,
				 ExpirtyDate		AS ExpirtyDate,
				 Price				AS Price,
				 @count				AS Count
			FROM #Temp_overstock
			WHERE  priority = @type
			ORDER BY QuantityOnHand DESC
			OFFSET  @PageSize * (@pageNumber - 1)   ROWS
			FETCH NEXT @PageSize ROWS ONLY	

			 
  END




GO
/****** Object:  StoredProcedure [dbo].[SP_surplus_oversupply_backup_15052018]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 05-04-2018
-- Description: SP to for oversupply/surplus
-- =============================================

CREATE PROC [dbo].[SP_surplus_oversupply_backup_15052018]
   @pharmacy_id			int,
   @PageSize			int,
   @PageNumber			int,
   @SearchString		nvarchar(100)=null,
   @type				int
   
	AS
   BEGIN
   
	 IF(@type=1)
		 BEGIN
			 EXEC SP_inventory_overstock @pharmacy_id,@PageSize,@PageNumber,@SearchString
		 END
     ELSE IF(@type=2)
	     BEGIN 
			 EXEC SP_surplus @pharmacy_id,@PageSize,@PageNumber,@SearchString
		 END  
 

  END




GO
/****** Object:  StoredProcedure [dbo].[SP_surplus_oversupply_backup_28052018]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO



-- =============================================

-- Author:      Priyanka Chandak

-- Create date: 05-04-2018

-- Description: SP to for oversupply/surplus

-- exec SP_surplus_oversupply 1417,10,1,'',2

-- =============================================



CREATE PROC [dbo].[SP_surplus_oversupply_backup_28052018]
   @pharmacy_id			INT,
   @PageSize			INT,
   @PageNumber			INT,
   @SearchString		NVARCHAR(100)=null,
   @type				INT

   

	AS

   BEGIN

   

	 IF(@type=1)

		 BEGIN		
		   --  SET @PageSize=0
			 EXEC SP_OverSupply @pharmacy_id,@PageSize,@PageNumber,@SearchString



		 END

     ELSE IF(@type=2)

	     BEGIN 			

		

			CREATE TABLE #Temp_Remaining_Surplus_Inventory(		

				InventoryId INT,		
				PharmacyId INT,
				WholesalerId  INT,
				NDC			BIGINT,
				MedicineName NVARCHAR(1000),		
				Price MONEY,
				QuantityOnHand DECIMAL(18,5),				
				OptimalQuantity DECIMAL(18,5),			
				created_on	DATETIME,
				expire_date	 DATETIME						
			) 
			
			INSERT INTO  #Temp_Remaining_Surplus_Inventory(InventoryId, PharmacyId,WholesalerId, NDC, MedicineName, price,QuantityOnHand, OptimalQuantity, created_on,expire_date)
				EXEC SP_Surplus_Inventory_rowdata @pharmacy_id

			 
			 DECLARE @count int;

			 SELECT @count =  ISNULL(COUNT(*),0) FROM #Temp_Remaining_Surplus_Inventory	
			 			 
			 SELECT		
				InventoryId,
				PharmacyId,
				WholesalerId,
				MedicineName,
				QuantityOnHand,
				OptimalQuantity,		
				NDC,
				@count AS Count,
				Price
			 FROM #Temp_Remaining_Surplus_Inventory 		
				WHERE PharmacyId=@pharmacy_id AND (MedicineName LIKE '%'+ISNULL(@SearchString,MedicineName)+'%')		
				ORDER BY InventoryId 

			 OFFSET  @PageSize * (@PageNumber - 1)   ROWS

			 FETCH NEXT @PageSize ROWS ONLY	
			 			
			DROP TABLE #Temp_Remaining_Surplus_Inventory		

		 END   

  END



GO
/****** Object:  StoredProcedure [dbo].[SP_surplusSummary]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 10-04-2018
-- Description: SP to show surplus Summary returns
--SP_surplusSummary 12
-- =============================================
CREATE PROC [dbo].[SP_surplusSummary]

  @pharmacy_id INT
    
	AS
   BEGIN
   
   DECLARE @loc_pharmacy_id INT
   SET @loc_pharmacy_id = @pharmacy_id

   DECLARE @lastdate			DATETIME
   DECLARE @returntowholesaler	MONEY=0
   DECLARE @liquidation			MONEY=0
   DECLARE @remainingsurplusitem MONEY=0
   DECLARE @total				DECIMAL(12,2)
   DECLARE @pastDate			DATETIME ;   
   DECLARE @threemonth			DECIMAL=0  
   DECLARE @avgquantity         DECIMAL=0
   DECLARE @check               DECIMAL=0
   SET @pastDate = DATEADD(month, 3, GETDATE());

	DECLARE @expired_month INT
	SELECT @expired_month = [expiry_month] FROM [Inv_Exp_Config]

	DECLARE @expires_month_before INT = @expired_month -1
	

   -------------------------------------------------------------------------

   /*
    recommended for transfer
    1) 3 month average usage is 15 units/3 months = 5 units per month. if we had more than 5 units on the shelf this would
	 classify as surplus recommended for return. provided it also  met the criteria for return to wholesaler:
	 a) Must be greater than 6 month expiration dating
     b) Must be unopened and Undamaged item
     c) Must be a product carried by wholesaler (a non-discontinued item) 
	 d) Non-C2 (narcotic controlled substance) inventory item.
   */
     
   CREATE TABLE #Temp_RecommendedForReturn(		
		inventory_id	INT,
		pharmacy_id		INT,		
		wholesaler_id	INT,		
		drug_name		NVARCHAR(1000),
		ndc				BIGINT,
		QuantityOnHand	DECIMAL(10,2),
		OptimalQuantity DECIMAL(10,2),		
		price			MONEY,
		expiration_date	DATETIME,
		[opened]		BIT,
		[damaged]		BIT,
		[non_c2]		BIT,
		[created_on]	DATETIME
	)
	
	
	INSERT INTO  #Temp_RecommendedForReturn(inventory_id, pharmacy_id, wholesaler_id, drug_name, ndc,QuantityOnHand,OptimalQuantity,price,expiration_date,opened, damaged,non_c2,created_on )
  		EXEC SP_RecommendedForReturn_rawdata @loc_pharmacy_id		 	 			
				
	----------------------------------------------------------------------------
	SELECT @liquidation = ISNULL(SUM(ISNULL(temp_RFR.price,0)),0) FROM #Temp_RecommendedForReturn temp_RFR
	
	----------------------------------------------------------------------------
	/*
	 a) Must be greater than 6 month expiration dating
     b) Must be unopened and Undamaged item
     c) Must be a product carried by wholesaler (a non-discontinued item) 
	 d) Non-C2 (narcotic controlled substance) inventory item.
	*/
	UPDATE temp_RFR
		SET temp_RFR.expiration_date = EOMONTH(DATEADD(month, @expired_month ,temp_RFR.created_on))
	FROM #Temp_RecommendedForReturn temp_RFR
	
	CREATE TABLE #Temp_FinalResult_RecommendedForReturn(				
		ndc				BIGINT,				
		price			MONEY,
		expiration_date	DATETIME		
	)

	INSERT INTO  #Temp_FinalResult_RecommendedForReturn (ndc, price,expiration_date )
		SELECT 
			temp_RFR.ndc,
			ISNULL(temp_RFR.price,0) AS price,
			temp_RFR.expiration_date
		FROM #Temp_RecommendedForReturn temp_RFR
		INNER JOIN RX30_inventory inv_rx30 ON inv_rx30.[ndc] = temp_RFR.[ndc] 
		WHERE (
				( GETDATE() > DATEADD(month, 6 ,temp_RFR.expiration_date) ) AND /*Must be greater than 6 month expiration dating*/
				(ISNULL(temp_RFR.opened,0) = 0) AND
				(ISNULL(temp_RFR.damaged,0) = 0) AND
				(ISNULL(temp_RFR.non_c2,0) = 0) AND
				(inv_rx30.created_on > DATEADD(MONTH, -3, GETDATE()) ) /*Must be a product carried by wholesaler (a non-discontinued item) */
			)

	
	SELECT @returntowholesaler = ISNULL(SUM(ISNULL(temp_FRRR.price,0)),0) FROM #Temp_FinalResult_RecommendedForReturn temp_FRRR


	DROP TABLE #Temp_FinalResult_RecommendedForReturn	
	DROP TABLE #Temp_RecommendedForReturn
  ----------------------------------------------------------------------------
  
   /*
   3) Remaining Surplus Inventory= inventory remaining after all possible returns to wholesaler/possible transfers to other stores. 
		a. Basically this is going to be any inventory with less than 1 month expiration, expired inventory, or 
		b. inventory that has no usage by any other store - This condition need to discussed.

   */	
	CREATE TABLE #Temp_Remaining_Surplus_Inventory(		
		inventory_id INT,		
		pharmacy_id INT,
		WholesalerId INT,
		ndc			BIGINT,
		drug_name	NVARCHAR(1000),		
		price MONEY,
		QuantityOnHand DECIMAL(18,5),				
		OptimalQuantity DECIMAL(18,5),
		created_on	DATETIME,
		expire_date	 DATETIME
	) 

	INSERT INTO  #Temp_Remaining_Surplus_Inventory(inventory_id, pharmacy_id, WholesalerId, ndc,drug_name, price,QuantityOnHand,OptimalQuantity, created_on,expire_date)
		EXEC SP_Surplus_Inventory_rowdata @loc_pharmacy_id

	SELECT @remainingsurplusitem =ISNULL((SUM(price)),0)	FROM #Temp_Remaining_Surplus_Inventory 		
	
	DROP TABLE #Temp_Remaining_Surplus_Inventory
  ----------------------------------------------------------------------------
  
	

  SET @total=@returntowholesaler + @liquidation + @remainingsurplusitem
  
    CREATE TABLE #Temp_surplusSummary
	(
	 returntowholesaler    MONEY,
	 liquidation           MONEY, 
	 remainingsurplusitem  MONEY, 
	 total				   DECIMAL(12,2)
	)
	INSERT INTO #Temp_surplusSummary
    (returntowholesaler,liquidation,remainingsurplusitem,total) VALUES
	(@returntowholesaler,@liquidation,@remainingsurplusitem,@total)	

	
	SELECT 	 
	 returntowholesaler		    AS ReturnToWholesaler,
	 liquidation				AS Liquidation,
	 remainingsurplusitem		AS RemainingSurplusItem,
	 total						AS Total	
	 FROM #Temp_surplusSummary

	 DROP TABLE #Temp_surplusSummary

  END

  -- 



  



GO
/****** Object:  StoredProcedure [dbo].[SP_surplusSummary_backup_1505218_01]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 10-04-2018
-- Description: SP to show surplus Summary returns
--SP_surplusSummary 1517
-- =============================================
CREATE PROC [dbo].[SP_surplusSummary_backup_1505218_01]

  @pharmacy_id INT
    
	AS
   BEGIN
   DECLARE @lastdate			DATETIME
   DECLARE @returntowholesaler	MONEY=0
   DECLARE @liquidation			MONEY=0
   DECLARE @remainingsurplusitem MONEY=0
   DECLARE @total				DECIMAL(12,2)
   DECLARE @pastDate			DATETIME ;   
   DECLARE @threemonth			DECIMAL=0  
   DECLARE @avgquantity         DECIMAL=0
   DECLARE @check               DECIMAL=0
   SET @pastDate = DATEADD(month, 3, GETDATE());

	DECLARE @expired_month INT
	SELECT @expired_month = [expiry_month] FROM [Inv_Exp_Config]

	DECLARE @expires_month_before INT = @expired_month -1
	

   -------------------------------------------------------------------------

   /*
    recommended for transfer
    1) 3 month average usage is 15 units/3 months = 5 units per month. if we had more than 5 units on the shelf this would
	 classify as surplus recommended for return. provided it also  met the criteria for return to wholesaler:
	 a) Must be greater than 6 month expiration dating
     b) Must be unopened and Undamaged item
     c) Must be a product carried by wholesaler (a non-discontinued item) 
	 d) Non-C2 (narcotic controlled substance) inventory item.
   */
     
   CREATE TABLE #Temp_RecommendedForReturn(		
		pharmacy_id		INT,		
		ndc				BIGINT,
		QuantityOnHand	DECIMAL(10,2),
		OptimalQuantity DECIMAL(10,2),		
		price			MONEY,
		expiration_date	DATETIME,
		[opened]		BIT,
		[damaged]		BIT,
		[non_c2]		BIT,
		[created_on]	DATETIME
	)
	
	
	INSERT INTO  #Temp_RecommendedForReturn(pharmacy_id,ndc,QuantityOnHand,OptimalQuantity,price,expiration_date,opened, damaged,non_c2,created_on )
  		SELECT		
			 inv.pharmacy_id						AS pharmacy_id,		
			 inv.ndc								AS ndc,
			 inv.pack_size							AS QuantityOnHand,
			 dbo.FN_calculate_optimum_qty(ndc,@pharmacy_id)	AS OptimalQuantity,		 
			 inv.price								AS Price,
			 NULL, 
			 inv.[opened]							AS opened,
			 inv.[damaged]							AS damaged,
			 inv.[non_c2]							AS non_c2,
			 inv.[created_on]		
		 FROM [dbo].[inventory] inv

		 WHERE 	(
			(inv.pharmacy_id = @pharmacy_id) AND 
			(ISNULL(inv.is_deleted,0) = 0) AND 
			(ISNULL(inv.pack_size,0) > 0) 			
		 )
		 	 		
	

	DELETE FROM #Temp_RecommendedForReturn WHERE ISNULL(OptimalQuantity,0) = 0
	DELETE FROM #Temp_RecommendedForReturn WHERE ISNULL(QuantityOnHand,0) < ISNULL(OptimalQuantity,0)
	
	----------------------------------------------------------------------------
	SELECT @liquidation = ISNULL(SUM(ISNULL(temp_RFR.price,0)),0) FROM #Temp_RecommendedForReturn temp_RFR
	
	----------------------------------------------------------------------------
	/*
	 a) Must be greater than 6 month expiration dating
     b) Must be unopened and Undamaged item
     c) Must be a product carried by wholesaler (a non-discontinued item) 
	 d) Non-C2 (narcotic controlled substance) inventory item.
	*/
	UPDATE temp_RFR
		SET temp_RFR.expiration_date = EOMONTH(DATEADD(month, @expired_month ,temp_RFR.created_on))
	FROM #Temp_RecommendedForReturn temp_RFR
	
	CREATE TABLE #Temp_FinalResult_RecommendedForReturn(				
		ndc				BIGINT,				
		price			MONEY,
		expiration_date	DATETIME		
	)

	INSERT INTO  #Temp_FinalResult_RecommendedForReturn (ndc, price,expiration_date )
		SELECT 
			temp_RFR.ndc,
			ISNULL(temp_RFR.price,0) AS price,
			temp_RFR.expiration_date
		FROM #Temp_RecommendedForReturn temp_RFR
		INNER JOIN RX30_inventory inv_rx30 ON inv_rx30.[ndc] = temp_RFR.[ndc] 
		WHERE (
				( GETDATE() > DATEADD(month, 6 ,temp_RFR.expiration_date) ) AND /*Must be greater than 6 month expiration dating*/
				(ISNULL(temp_RFR.opened,0) = 0) AND
				(ISNULL(temp_RFR.damaged,0) = 0) AND
				(ISNULL(temp_RFR.non_c2,0) = 0) AND
				(inv_rx30.created_on > DATEADD(MONTH, -3, GETDATE()) ) /*Must be a product carried by wholesaler (a non-discontinued item) */
			)

	
	SELECT @returntowholesaler = ISNULL(SUM(ISNULL(temp_FRRR.price,0)),0) FROM #Temp_FinalResult_RecommendedForReturn temp_FRRR


	DROP TABLE #Temp_FinalResult_RecommendedForReturn	
	DROP TABLE #Temp_RecommendedForReturn
  ----------------------------------------------------------------------------
  
   /*
   3) Remaining Surplus Inventory= inventory remaining after all possible returns to wholesaler/possible transfers to other stores. 
		a. Basically this is going to be any inventory with less than 1 month expiration, expired inventory, or 
		b. inventory that has no usage by any other store - This condition need to discussed.

   */	
	CREATE TABLE #Temp_Remaining_Surplus_Inventory(		
		inventory_id INT,		
		pharmacy_id INT,
		ndc			INT,		
		price MONEY,
		created_on	DATETIME,
		expire_date	 DATETIME
	) 

	INSERT INTO  #Temp_Remaining_Surplus_Inventory(inventory_id, pharmacy_id,ndc, price,created_on,expire_date)
		SELECT inv.inventory_id, inv.pharmacy_id,INV.ndc, inv.price,inv.created_on,EOMONTH(DATEADD(month, @expired_month ,inv.created_on)) as expire_date 
		FROM inventory inv
		WHERE (
			(inv.pharmacy_id=@pharmacy_id) AND 
			(ISNULL(inv.is_deleted,0)=0) AND
			(ISNULL(inv.pack_size,0) > 0) AND
			(
				((EOMONTH(DATEADD(month, @expires_month_before ,inv.created_on))) <= EOMONTH(GETDATE())) OR 
				((EOMONTH(DATEADD(month, @expired_month ,inv.created_on))) <= EOMONTH(GETDATE()))
			)
		)

	SELECT @remainingsurplusitem =ISNULL((SUM(price)),0)	FROM #Temp_Remaining_Surplus_Inventory 		
	
	DROP TABLE #Temp_Remaining_Surplus_Inventory
  ----------------------------------------------------------------------------
  
	

  SET @total=@returntowholesaler + @liquidation + @remainingsurplusitem
  
    CREATE TABLE #Temp_surplusSummary
	(
	 returntowholesaler    MONEY,
	 liquidation           MONEY, 
	 remainingsurplusitem  MONEY, 
	 total				   DECIMAL(12,2)
	)
	INSERT INTO #Temp_surplusSummary
    (returntowholesaler,liquidation,remainingsurplusitem,total) VALUES
	(@returntowholesaler,@liquidation,@remainingsurplusitem,@total)	

	
	SELECT 	 
	 returntowholesaler		    AS ReturnToWholesaler,
	 liquidation				AS Liquidation,
	 remainingsurplusitem		AS RemainingSurplusItem,
	 total						AS Total	
	 FROM #Temp_surplusSummary

	 DROP TABLE #Temp_surplusSummary

  END

  -- 



  




GO
/****** Object:  StoredProcedure [dbo].[SP_surplusSummary_bk_06102019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 10-04-2018
-- Description: SP to show surplus Summary returns
--SP_surplusSummary 12
-- =============================================
CREATE PROC [dbo].[SP_surplusSummary_bk_06102019]

  @pharmacy_id INT
    
	AS
   BEGIN
   DECLARE @lastdate			DATETIME
   DECLARE @returntowholesaler	MONEY=0
   DECLARE @liquidation			MONEY=0
   DECLARE @remainingsurplusitem MONEY=0
   DECLARE @total				DECIMAL(12,2)
   DECLARE @pastDate			DATETIME ;   
   DECLARE @threemonth			DECIMAL=0  
   DECLARE @avgquantity         DECIMAL=0
   DECLARE @check               DECIMAL=0
   SET @pastDate = DATEADD(month, 3, GETDATE());

	DECLARE @expired_month INT
	SELECT @expired_month = [expiry_month] FROM [Inv_Exp_Config]

	DECLARE @expires_month_before INT = @expired_month -1
	

   -------------------------------------------------------------------------

   /*
    recommended for transfer
    1) 3 month average usage is 15 units/3 months = 5 units per month. if we had more than 5 units on the shelf this would
	 classify as surplus recommended for return. provided it also  met the criteria for return to wholesaler:
	 a) Must be greater than 6 month expiration dating
     b) Must be unopened and Undamaged item
     c) Must be a product carried by wholesaler (a non-discontinued item) 
	 d) Non-C2 (narcotic controlled substance) inventory item.
   */
     
   CREATE TABLE #Temp_RecommendedForReturn(		
		inventory_id	INT,
		pharmacy_id		INT,		
		wholesaler_id	INT,		
		drug_name		NVARCHAR(1000),
		ndc				BIGINT,
		QuantityOnHand	DECIMAL(10,2),
		OptimalQuantity DECIMAL(10,2),		
		price			MONEY,
		expiration_date	DATETIME,
		[opened]		BIT,
		[damaged]		BIT,
		[non_c2]		BIT,
		[created_on]	DATETIME
	)
	
	
	INSERT INTO  #Temp_RecommendedForReturn(inventory_id, pharmacy_id, wholesaler_id, drug_name, ndc,QuantityOnHand,OptimalQuantity,price,expiration_date,opened, damaged,non_c2,created_on )
  		EXEC SP_RecommendedForReturn_rawdata @pharmacy_id		 	 			
				
	----------------------------------------------------------------------------
	SELECT @liquidation = ISNULL(SUM(ISNULL(temp_RFR.price,0)),0) FROM #Temp_RecommendedForReturn temp_RFR
	
	----------------------------------------------------------------------------
	/*
	 a) Must be greater than 6 month expiration dating
     b) Must be unopened and Undamaged item
     c) Must be a product carried by wholesaler (a non-discontinued item) 
	 d) Non-C2 (narcotic controlled substance) inventory item.
	*/
	UPDATE temp_RFR
		SET temp_RFR.expiration_date = EOMONTH(DATEADD(month, @expired_month ,temp_RFR.created_on))
	FROM #Temp_RecommendedForReturn temp_RFR
	
	CREATE TABLE #Temp_FinalResult_RecommendedForReturn(				
		ndc				BIGINT,				
		price			MONEY,
		expiration_date	DATETIME		
	)

	INSERT INTO  #Temp_FinalResult_RecommendedForReturn (ndc, price,expiration_date )
		SELECT 
			temp_RFR.ndc,
			ISNULL(temp_RFR.price,0) AS price,
			temp_RFR.expiration_date
		FROM #Temp_RecommendedForReturn temp_RFR
		INNER JOIN RX30_inventory inv_rx30 ON inv_rx30.[ndc] = temp_RFR.[ndc] 
		WHERE (
				( GETDATE() > DATEADD(month, 6 ,temp_RFR.expiration_date) ) AND /*Must be greater than 6 month expiration dating*/
				(ISNULL(temp_RFR.opened,0) = 0) AND
				(ISNULL(temp_RFR.damaged,0) = 0) AND
				(ISNULL(temp_RFR.non_c2,0) = 0) AND
				(inv_rx30.created_on > DATEADD(MONTH, -3, GETDATE()) ) /*Must be a product carried by wholesaler (a non-discontinued item) */
			)

	
	SELECT @returntowholesaler = ISNULL(SUM(ISNULL(temp_FRRR.price,0)),0) FROM #Temp_FinalResult_RecommendedForReturn temp_FRRR


	DROP TABLE #Temp_FinalResult_RecommendedForReturn	
	DROP TABLE #Temp_RecommendedForReturn
  ----------------------------------------------------------------------------
  
   /*
   3) Remaining Surplus Inventory= inventory remaining after all possible returns to wholesaler/possible transfers to other stores. 
		a. Basically this is going to be any inventory with less than 1 month expiration, expired inventory, or 
		b. inventory that has no usage by any other store - This condition need to discussed.

   */	
	CREATE TABLE #Temp_Remaining_Surplus_Inventory(		
		inventory_id INT,		
		pharmacy_id INT,
		WholesalerId INT,
		ndc			BIGINT,
		drug_name	NVARCHAR(1000),		
		price MONEY,
		QuantityOnHand DECIMAL(18,5),				
		OptimalQuantity DECIMAL(18,5),
		created_on	DATETIME,
		expire_date	 DATETIME
	) 

	INSERT INTO  #Temp_Remaining_Surplus_Inventory(inventory_id, pharmacy_id, WholesalerId, ndc,drug_name, price,QuantityOnHand,OptimalQuantity, created_on,expire_date)
		EXEC SP_Surplus_Inventory_rowdata @pharmacy_id

	SELECT @remainingsurplusitem =ISNULL((SUM(price)),0)	FROM #Temp_Remaining_Surplus_Inventory 		
	
	DROP TABLE #Temp_Remaining_Surplus_Inventory
  ----------------------------------------------------------------------------
  
	

  SET @total=@returntowholesaler + @liquidation + @remainingsurplusitem
  
    CREATE TABLE #Temp_surplusSummary
	(
	 returntowholesaler    MONEY,
	 liquidation           MONEY, 
	 remainingsurplusitem  MONEY, 
	 total				   DECIMAL(12,2)
	)
	INSERT INTO #Temp_surplusSummary
    (returntowholesaler,liquidation,remainingsurplusitem,total) VALUES
	(@returntowholesaler,@liquidation,@remainingsurplusitem,@total)	

	
	SELECT 	 
	 returntowholesaler		    AS ReturnToWholesaler,
	 liquidation				AS Liquidation,
	 remainingsurplusitem		AS RemainingSurplusItem,
	 total						AS Total	
	 FROM #Temp_surplusSummary

	 DROP TABLE #Temp_surplusSummary

  END

  -- 



  



GO
/****** Object:  StoredProcedure [dbo].[sp_test1]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

create procedure [dbo].[sp_test1]
as
begin
insert into #temp
select getdate();
select getdate();
end;




GO
/****** Object:  StoredProcedure [dbo].[sp_test2]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

create procedure [dbo].[sp_test2]
as
begin
create table #temp (MYDATE DATETIME);

exec sp_test1;

select * from #temp;

end;




GO
/****** Object:  StoredProcedure [dbo].[SP_topdollaritems]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Create date: 10-05-2018
-- Description: SP to show return top 10 dollar items
-- EXEC SP_topdollaritems 1417
-- =============================================

CREATE PROC [dbo].[SP_topdollaritems]
 @pharmacy_id  int

	AS 
	BEGIN
	DECLARE @minValue MONEY = 250.00

		--select top 3
		--L.ndc_upc    AS NDC,
		--L.unit_price AS UnitPrice,
		--D.product_desc  AS DrugName
	 --   from invoice I 
		--Join invoice_line_items L ON I.invoice_id=L.invoice_id 
		--JOIN invoice_productDescription D ON L.invoice_lineitem_id=D.invoice_items_id
		--JOIN inventory inv ON inv.ndc = ISNULL(TRY_PARSE(L.ndc_upc AS BIGINT),0) 
		--where I.pharmacy_id=@pharmacy_id AND I.is_deleted=0 AND inv.pack_size>0 and inv.is_deleted=0
		--order by L.unit_price desc 

		SELECT top 3 
		convert(NVARCHAR(500), ndc)    AS NDC,
		price AS UnitPrice,
		drug_name  AS DrugName

		FROM [dbo].[inventory]
		WHERE price >= @minValue 
		AND pharmacy_id = @pharmacy_id
		AND (ISNULL(is_deleted,0) = 0)  
		AND	(ISNULL(pack_size,0) > 0) 
		ORDER BY price DESC
		
	END

	--exec SP_topdollaritems 1
	



GO
/****** Object:  StoredProcedure [dbo].[SP_topReimburesement]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- SP_topReimburesement 1417,430042014
CREATE PROC [dbo].[SP_topReimburesement]
(
@pharmacyId   INT,
@ndc          BIGINT
)
AS 
BEGIN 

    	SELECT I.ndc,R.generic_code AS GenericCode INTO #Temp_genericdata
		FROM inventory I JOIN rx30_inventory R
		ON I.ndc=R.ndc
		WHERE  ((I.pharmacy_id =@pharmacyId )
		AND  (I.ndc =@ndc) 
		AND (R.plan_name != '') AND (R.plan_paid>0))


		SELECT 
	    R.plan_name AS PlanName, 
	   ((ISNULL(SUM(R.plan_paid),0) + ISNULL(SUM(R.pat_paid),0)))/(ISNULL(SUM(R.qty_disp),1)) AS Amount,
	    R.ndc	  AS NDC,
		0         AS Bin	
	    INTO #Temp_Reimburement
	    FROM Rx30_inventory R JOIN #Temp_genericdata G
	    ON R.generic_code=G.GenericCode
	    WHERE ((R.pharmacy_id =@pharmacyId) and (R.plan_paid>0)
	   )	   
	  GROUP BY  R.plan_name,R.ndc

	  UPDATE tempRem 	  
	  SET tempRem.Bin = ISNULL((R.bin),0)
	  FROM  #Temp_Reimburement tempRem
	  INNER JOIN Rx30_inventory R ON tempRem.NDC = R.ndc 

	  SELECT TOP 5 * FROM #Temp_Reimburement ORDER BY Amount DESC


	  --select top 5 t.*,R.bin from #Temp_Reimburement t JOIN Rx30_inventory R
	  --ON t.NDC = R.ndc	   
	  -- order by Amount desc
	
END

GO
/****** Object:  StoredProcedure [dbo].[sp_transfer_management]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
--EXEC sp_transfer_management 11,20,1,''

CREATE PROC [dbo].[sp_transfer_management]

  @pharmacy_id  int,
  @PageSize		int,
  @PageNumber    int,
  @SearchString  nvarchar(100)=null


  AS
   BEGIN
   DECLARE @count int;

   SELECT
    T.transfer_mgmt_id			AS  TransferMgmtId,
	T.mp_postitem_id			AS  MpPostitemId,
	T.purchaser_pharmacy_id		AS  PurchaserPharmacyId,
	T.seller_pharmacy_id		AS  SellerPharmacyId,
	P.drug_name					AS  DrugName,
	P.ndc_code					AS  NDC,
	P.strength					AS  Strength,
	T.updated_quantity			AS  UpdatedQuantity,
	ROUND(P.sales_price,2)		AS  SalesPrice
   into #Temp_transfermgmt
   FROM transfer_management T JOIN mp_post_items P 
   ON T.mp_postitem_id = P.mp_postitem_id
   WHERE T.seller_pharmacy_id=@pharmacy_id AND ISNULL(T.is_deletd,0)= 0



    SELECT @count=  IsNull(COUNT(*),0) FROM #Temp_transfermgmt where (DrugName LIKE '%'+ISNULL(@SearchString,DrugName)+'%' OR
		 NDC LIKE '%'+ISNULL(@SearchString,NDC)+'%')
		 
		 select *,@count AS Count from #Temp_transfermgmt
		 where (DrugName LIKE '%'+ISNULL(@SearchString,DrugName)+'%' OR
		 NDC LIKE '%'+ISNULL(@SearchString,NDC)+'%')
		 ORDER BY TransferMgmtId desc
		 OFFSET  @PageSize * (@PageNumber - 1)   ROWS
         FETCH NEXT @PageSize ROWS ONLY	


   DROP TABLE #Temp_transfermgmt

   END

GO
/****** Object:  StoredProcedure [dbo].[SP_transfermanagementList]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Lata Bisht
-- Create date: 06-04-2018
-- Description: SP to show transfermanagement list with pagination and serarching
-- =============================================


create PROC [dbo].[SP_transfermanagementList]
  @pharmacy_id  int,
  @PageSize		int,
  @PageNumber    int,
  @SearchString  nvarchar(100)=null

	AS
   BEGIN
   DECLARE @count int;
     SELECT @count=COUNT(*) FROM inventory;
  	SELECT
	     inventory_id					  AS Id,
		 pharmacy_id					  AS PharmacyId,
		
		 drug_name						  AS DrugName,
		 ndc							  AS NDC,
						  
		 pack_size	
		                                  AS PackSize,
		 price					
							              AS Price,
		 @count                           As Count
		        
		 FROM [dbo].[inventory] 
		 WHERE 	pharmacy_id = @pharmacy_id AND (drug_name LIKE '%'+ISNULL(@SearchString,drug_name)+'%' OR
		 ndc LIKE '%'+ISNULL(@SearchString,ndc)+'%')
		 ORDER BY inventory_id desc
		 OFFSET  @PageSize * (@PageNumber - 1)   ROWS
         FETCH NEXT @PageSize ROWS ONLY	

  END



GO
/****** Object:  StoredProcedure [dbo].[SP_underSupply]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================  
-- Create date: 27-03-2018  
-- Description: SP to show undersupply(forcasting) of medicines  
--EXEC SP_underSupply 1417,10,1,''  
-- =============================================  
  
CREATE PROC [dbo].[SP_underSupply]  
  @pharmacy_id int,  
  @PageSize  int,  
  @PageNumber    int,    
  @SearchString  nvarchar(100)=null  
      
 AS  
   BEGIN  
  
 DECLARE @count int;        
 DECLARE @expired_month INT      
 SELECT @expired_month = [expiry_month] FROM [Inv_Exp_Config]     
   
   
 CREATE TABLE #Temp_UnderSupply(      
   InventoryId INT,       
   PharmacyId INT,      
   WholesalerId INT,      
   MedicineName NVARCHAR(500),      
   QuantityOnHand DECIMAL(10,2),      
   OptimalQuantity DECIMAL(10,2),      
   ExpirtyDate  DATETIME,      
   Price  DECIMAL(12,2),      
   NDC BIGINT,      
   Strength NVARCHAR(100),      
   Count  INT      
        
 )      
      
 INSERT INTO  #Temp_UnderSupply(InventoryId, PharmacyId,WholesalerId,MedicineName,QuantityOnHand,OptimalQuantity,ExpirtyDate,Price,NDC,Strength)       
 EXEC SP_underSupply_rawdata @pharmacy_id     
  
   SELECT   
   InventoryId ,       
   PharmacyId ,      
   WholesalerId ,      
   MedicineName ,      
   QuantityOnHand ,      
   OptimalQuantity ,      
   ExpirtyDate ,      
   ((OptimalQuantity - QuantityOnHand) * Price)  AS  Price  ,      
   NDC ,      
   Strength ,      
   COUNT(1) OVER () AS Count       
   from #Temp_UnderSupply   
   WHERE (      
  (MedicineName LIKE '%'+ISNULL(@SearchString,MedicineName)+'%') OR      
  (NDC LIKE '%'+ISNULL(@SearchString,NDC)+'%')      
  ) AND (ISNULL(QuantityOnHand,0) <> 0)   
   ORDER BY WholesalerId   
   OFFSET  @PageSize * (@PageNumber - 1)   ROWS      
   FETCH NEXT IIF(@PageSize = 0, 100000, @PageSize) ROWS ONLY       
   
  
  END  
  
  
GO
/****** Object:  StoredProcedure [dbo].[SP_underSupply_bk13032019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================  
-- Create date: 27-03-2018  
-- Description: SP to show undersupply(forcasting) of medicines  
--EXEC SP_underSupply_bk13032019 1417,10,1,''  
-- =============================================  
  
CREATE PROC [dbo].[SP_underSupply_bk13032019]  
  @pharmacy_id int,  
  @PageSize  int,  
  @PageNumber    int,    
  @SearchString  nvarchar(100)=null  
      
 AS  
   BEGIN  
  
    DECLARE @count int;    
 DECLARE @expired_month INT  
 SELECT @expired_month = [expiry_month] FROM [Inv_Exp_Config]  
  
 CREATE TABLE #Temp_UnderSupply(  
  InventoryId INT,   
  PharmacyId INT,  
  WholesalerId INT,  
  MedicineName NVARCHAR(500),  
  QuantityOnHand DECIMAL(10,2),  
  OptimalQuantity DECIMAL(10,2),  
  ExpirtyDate  DATETIME,  
  Price  DECIMAL(12,2),  
  NDC BIGINT,  
  Strength NVARCHAR(100),  
  Count  INT  
    
 )  
  
 INSERT INTO  #Temp_UnderSupply(InventoryId, PharmacyId,WholesalerId,MedicineName,QuantityOnHand,OptimalQuantity,ExpirtyDate,Price,NDC,Strength)  
    EXEC SP_underSupply_rawdata @pharmacy_id  
   
 DELETE FROM #Temp_UnderSupply WHERE (  
           (ISNULL(QuantityOnHand,0) < = 0)            
          )  
  
   
  
   SELECT  @count = ISNULL (COUNT(*),0) FROM #Temp_UnderSupply  WHERE (  
    (MedicineName LIKE '%'+ISNULL(@SearchString,MedicineName)+'%') OR  
    (NDC LIKE '%'+ISNULL(@SearchString,NDC)+'%')  
    /*AND (ExpirtyDate > GETDATE()) */  
    )  
  
     UPDATE #Temp_UnderSupply SET Count=@count  
  
    
  
   IF @PageSize > 0  
  BEGIN  
 SELECT   
  InventoryId,PharmacyId,WholesalerId,MedicineName,QuantityOnHand , OptimalQuantity, ExpirtyDate,  
  ((OptimalQuantity - QuantityOnHand) * Price)  AS  Price  ,  
  NDC ,Count,Strength  
  FROM #Temp_UnderSupply   
  WHERE (  
    (MedicineName LIKE '%'+ISNULL(@SearchString,MedicineName)+'%') OR  
    (NDC LIKE '%'+ISNULL(@SearchString,NDC)+'%')  
    )  
   ORDER BY WholesalerId  
   OFFSET  @PageSize * (@PageNumber - 1)   ROWS  
        FETCH NEXT @PageSize ROWS ONLY  
    
 END  
 ELSE  
 BEGIN  
 SELECT   
  InventoryId,PharmacyId,WholesalerId,MedicineName,QuantityOnHand , OptimalQuantity, ExpirtyDate,  
  ((OptimalQuantity - QuantityOnHand) * Price)  AS  Price  ,  
  NDC ,Count ,Strength  
  FROM #Temp_UnderSupply   
  WHERE (  
    (MedicineName LIKE '%'+ISNULL(@SearchString,MedicineName)+'%') OR  
    (NDC LIKE '%'+ISNULL(@SearchString,NDC)+'%')  
    )  
   ORDER BY WholesalerId   
 END    
   
  
  END  
  
  
GO
/****** Object:  StoredProcedure [dbo].[SP_underSupply_rawdata]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================  
  
-- Create date: 27-03-2018  
-- Description: SP to show undersupply(forcasting) of medicines  
--EXEC SP_underSupply_rawdata 12  
-- =============================================  
  
CREATE PROC [dbo].[SP_underSupply_rawdata]  
  @pharmacy_id INT        
 AS  
   BEGIN  
 
 DECLARE @loc_pharmacy_id INT  
 SET	@loc_pharmacy_id = @pharmacy_id        

 DECLARE @expired_month INT              
 DECLARE @cdate DATETIME = DATEADD(month, -3, GETDATE())              
 SELECT @expired_month = [expiry_month] FROM [Inv_Exp_Config]              
            
 ;WITH UnderSupply AS (            
   SELECT            
              
		inv.inventory_id      AS InventoryId,                  
		inv.pharmacy_id      AS PharmacyId,              
		ISNULL(inv.wholesaler_id,0)          AS WholesalerId,               
		inv.drug_name       AS MedicineName,         
		inv.pack_size       AS QuantityOnHand,        
		ROUND(opt,0)       AS OptimalQuantity,         
		EOMONTH(DATEADD(month, @expired_month ,ISNULL(created_on,GETDATE()))) AS ExpirtyDate,          
		inv.price        AS Price,                 
		inv.ndc        AS NDC,                              
		inv.Strength       AS Strength                 
   FROM [dbo].[inventory] inv    
  /*Begin:03/07/2019: Humera: calculating optimal quantity*/              
	  CROSS APPLY (              
		   SELECT SUM(qty_disp) / 3 AS opt              
		   FROM [dbo].[RX30_inventory] rx               
		   WHERE rx.ndc = inv.ndc AND rx.pharmacy_id = @loc_pharmacy_id AND rx.created_on >= @cdate AND rx.is_deleted IS NULL              
	  ) rx    
  /*Begin: End*/                         
	   WHERE  (              
	   (inv.pharmacy_id = @loc_pharmacy_id ) AND               
		(ISNULL(inv.is_deleted,0) = 0)                         
	   )             
   )                  
        
   SELECT            
	  InventoryId ,              
	  PharmacyId  ,                
	  WholesalerId ,                
	  MedicineName  ,          
	  QuantityOnHand ,              
	  OptimalQuantity ,        
	  ExpirtyDate ,       
	  price   ,             
	  NDC    ,                       
	  Strength                      
   FROM  UnderSupply US        
   WHERE   (QuantityOnHand < (OptimalQuantity * 0.7) )      
  END  
  
  
  


GO
/****** Object:  StoredProcedure [dbo].[SP_underSupply_rawdata_bk_06102019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================  
  
-- Create date: 27-03-2018  
-- Description: SP to show undersupply(forcasting) of medicines  
--EXEC SP_underSupply_rawdata 12  
-- =============================================  
  
CREATE PROC [dbo].[SP_underSupply_rawdata_bk_06102019]  
  @pharmacy_id INT        
 AS  
   BEGIN  
  
                  
 DECLARE @expired_month INT              
 DECLARE @cdate DATETIME = DATEADD(month, -3, GETDATE())              
 SELECT @expired_month = [expiry_month] FROM [Inv_Exp_Config]              
            
 ;WITH UnderSupply AS (            
   SELECT            
              
		inv.inventory_id      AS InventoryId,                  
		inv.pharmacy_id      AS PharmacyId,              
		ISNULL(inv.wholesaler_id,0)          AS WholesalerId,               
		inv.drug_name       AS MedicineName,         
		inv.pack_size       AS QuantityOnHand,        
		ROUND(opt,0)       AS OptimalQuantity,         
		EOMONTH(DATEADD(month, @expired_month ,ISNULL(created_on,GETDATE()))) AS ExpirtyDate,          
		inv.price        AS Price,                 
		inv.ndc        AS NDC,                              
		inv.Strength       AS Strength                 
   FROM [dbo].[inventory] inv    
  /*Begin:03/07/2019: Humera: calculating optimal quantity*/              
	  CROSS APPLY (              
		   SELECT SUM(qty_disp) / 3 AS opt              
		   FROM [dbo].[RX30_inventory] rx               
		   WHERE rx.ndc = inv.ndc AND rx.pharmacy_id = inv.pharmacy_id AND rx.created_on >= @cdate AND rx.is_deleted IS NULL              
	  ) rx    
  /*Begin: End*/                         
	   WHERE  (              
	   (inv.pharmacy_id = @pharmacy_id ) AND               
		(ISNULL(inv.is_deleted,0) = 0)                         
	   )             
   )                  
        
   SELECT            
	  InventoryId ,              
	  PharmacyId  ,                
	  WholesalerId ,                
	  MedicineName  ,          
	  QuantityOnHand ,              
	  OptimalQuantity ,        
	  ExpirtyDate ,       
	  price   ,             
	  NDC    ,                       
	  Strength                      
   FROM  UnderSupply US        
   WHERE   (QuantityOnHand < (OptimalQuantity * 0.7) )      
  END  
  
  
  


GO
/****** Object:  StoredProcedure [dbo].[SP_underSupply_rawdata_BK13032019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================  
  
-- Create date: 27-03-2018  
-- Description: SP to show undersupply(forcasting) of medicines  
--EXEC SP_underSupply_rawdata_BK13032019 12  
-- =============================================  
  
CREATE PROC [dbo].[SP_underSupply_rawdata_BK13032019]  
  @pharmacy_id INT        
 AS  
   BEGIN  
  
    DECLARE @count int;    
 DECLARE @expired_month INT  
 SELECT @expired_month = [expiry_month] FROM [Inv_Exp_Config]  
  
 CREATE TABLE #Temp_UnderSupply(    
  InventoryId INT,  
  PharmacyId INT,  
  WholesalerId INT,  
  MedicineName NVARCHAR(500),  
  QuantityOnHand DECIMAL(10,2),  
  OptimalQuantity DECIMAL(10,2),  
  ExpirtyDate  DATETIME,  
  Price  DECIMAL(12,2),  
  NDC  BIGINT,  
  Strength  NVARCHAR(100)   
 )  
  
 INSERT INTO  #Temp_UnderSupply(InventoryId,PharmacyId,WholesalerId,MedicineName,QuantityOnHand,OptimalQuantity,ExpirtyDate,Price,NDC,Strength)  
   SELECT    
   inventory_id       AS InventoryId,   
   pharmacy_id       AS PharmacyId,  
   ISNULL(wholesaler_id,0)          AS WholesalerId,  
   drug_name        AS MedicineName,  
   pack_size        AS QuantityOnHand,  
   /*dbo.FN_calculate_optimum_qty(ndc,@pharmacy_id)AS OptimalQuantity,*/  
   0        AS OptimalQuantity,  
   EOMONTH(DATEADD(month, @expired_month, ISNULL(created_on,GETDATE()))) AS ExpirtyDate,  
   price         AS Price,  
   NDC         AS NDC ,  
   Strength           AS Strength    
  FROM [dbo].[inventory]   
  WHERE  (  
   (pharmacy_id = @pharmacy_id) AND (ISNULL(is_deleted,0) = 0)  
  )    
  
  /*This logic added to avoid calculating Optimum quantity for duplicate ndc*/  
  CREATE TABLE #Temp_UnderSupply_OQ(      
  NDC    BIGINT,    
  OptimalQuantity DECIMAL(10,2),  
  NDC_Count       INT    
 )  
  
 INSERT INTO #Temp_UnderSupply_OQ(NDC,OptimalQuantity,NDC_Count)  
  SELECT NDC,0,COUNT(NDC)  
  FROM #Temp_UnderSupply  
  GROUP BY NDC  
   
  /*Update Optimume quantity*/  
  UPDATE #Temp_UnderSupply_OQ  
  SET OptimalQuantity = dbo.FN_calculate_optimum_qty(NDC,@pharmacy_id)  
   
  UPDATE temp_US  
  SET temp_US.OptimalQuantity = temp_USOQ.OptimalQuantity  
  FROM #Temp_UnderSupply temp_US  
  INNER JOIN #Temp_UnderSupply_OQ temp_USOQ ON temp_USOQ.NDC = temp_US.NDC      
    
  /*----------------------------------------------------*/  
  
   
 DROP TABLE #Temp_UnderSupply_OQ  
  
  
  SELECT * FROM #Temp_UnderSupply   
  WHERE (QuantityOnHand < (OptimalQuantity * 0.7) )  
    
  DROP TABLE #Temp_UnderSupply          
  END  
  
  
  
  
GO
/****** Object:  StoredProcedure [dbo].[SP_update_NotificationStatus]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

--exec SP_update_NotificationStatus 1417,1
--select * from returnalert 
CREATE PROCEDURE [dbo].[SP_update_NotificationStatus]
(  
	  
	@pharmacy_id	   INTEGER,  
	@is_read			BIT
  
)  
  AS  
  BEGIN

	   UPDATE returnalert
	   SET is_read =@is_read 
	   WHERE (
			(FORMAT(alert_date,'MM/dd/yyyy') <= FORMAT(GETDATE(),'MM/dd/yyyy')) AND
			(pharmacy_id=@pharmacy_id)
			) 
 
  END


 


GO
/****** Object:  StoredProcedure [dbo].[SP_update_status_drugposting_notification]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author: Sagar Sharma     
-- Create date: 06-10-2018
-- Description: SP to Update the inventory after RX30 file.
-- =============================================

CREATE PROC [dbo].[SP_update_status_drugposting_notification]
	@ph_id			INT

	AS
   BEGIN
   UPDATE marketplace_drugpost_notification
   SET is_read=1 WHERE pharmacy_id = @ph_id
   
   
  END



GO
/****** Object:  StoredProcedure [dbo].[SP_update_status_drugpurchasing_notification]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author: Humera Sheikh     
-- Create date: 02-01-2019
-- Description: SP to Update the inventory after RX30 file.
-- =============================================

CREATE PROC [dbo].[SP_update_status_drugpurchasing_notification]
	@seller_ph_id			INT

	AS
   BEGIN
   UPDATE marketplace_drugpurchase_notification
   SET is_read=1 WHERE sellerpharmacy_id = @seller_ph_id
   
   
  END



GO
/****** Object:  StoredProcedure [dbo].[sp_update_strength_ndcpacksize]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


CREATE PROC [dbo].[sp_update_strength_ndcpacksize]
  AS 
	BEGIN
	
		CREATE TABLE #temp_edi_inv
			(
				LINndc			BIGINT,
				strength		NVARCHAR(1000),
				ndc_packsize	DECIMAL(10,2)
			)

/*get all the distinct ndc as bigint type along with strength and ndc pack size in a temp table(#temp_edi_inv)*/
INSERT INTO #temp_edi_inv (LINndc,strength,ndc_packsize)
	SELECT 
			DISTINCT CAST(LIN_NDC AS BIGINT),
			PID_Strength,
			(CAST(ISNULL([PO4_Pack_FDBSize],1) AS DECIMAL(10,2)) * CAST(ISNULL([PO4_Pack_MetricSize],1) AS DECIMAL(10,2)))
	FROM edi_inventory
	WHERE IsNumeric(LIN_NDC)=1 and 
		  PID_Strength IS NOT NULL



/*update the inventory table where strength and ndc_pack_size are null.*/ 
UPDATE  inv
			SET
				inv.Strength     =	tediinv.strength,
				inv.NDC_Packsize =  tediinv.ndc_packsize

			FROM inventory inv
			INNER JOIN #temp_edi_inv tediinv ON inv.ndc = tediinv.LINndc 
				WHERE inv.Strength IS NULL AND ISNULL(inv.NDC_Packsize,0)=0  


Drop table #temp_edi_inv

END


GO
/****** Object:  StoredProcedure [dbo].[SP_update_wholesaler_ftpdetails]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================
-- Author:      Sagar Sharma
-- Create date: 09-04-2018
-- Description: SP to UPDATE the wholesaler wholesaler FTP details
-- =============================================

CREATE PROCEDURE [dbo].[SP_update_wholesaler_ftpdetails]
	(
	@edicongifId		int,
	@wholesalerId		int,
	@ediAccountNumber   nvarchar(100),
	@username			nvarchar(90),
	@password			nvarchar(50),
	@port				int,
	@host				nvarchar(400),	
	@documentpath		nvarchar(400),
	@isactive			bit,
	@createdby			int
	
	)
 AS 
 BEGIN
	
	IF(@edicongifId = 0)
	  BEGIN
		
		  INSERT INTO edi_server_configuration(wholeseller_id, username, password, port, host, documentpath, IsActive,created_on, created_by, is_deleted,edi_account_number)
		   VALUES
		  (@wholesalerId, @username, @password, @port, @host, @documentpath, @isactive, GETDATE(), @createdby, 0,@ediAccountNumber) 
			
	   END 
	ELSE 
		BEGIN
			UPDATE edi_server_configuration SET

			wholeseller_id	=@wholesalerId,
			username		=@username, 
			password		=@password, 
			port			=@port, 
			host			=@host,
			documentpath	=@documentpath,
			IsActive		=@isactive,
			updated_on		=GETDATE(), 
			updated_by		=@createdby,
			edi_account_number =  @ediAccountNumber
			where 
			edi_config_id	= @edicongifId

	END


END;




GO
/****** Object:  StoredProcedure [dbo].[SP_userList]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO



--select * from  [dbo].[pharmacy_users]
--select * from 
--[dbo].[address_master]
-- =============================================
-- Author:      Priyanka Chandak
-- Create date: 18-06-2018
-- Description: SP to show user list with pagination and serarching
--SP_userList 1417,10,1,'S'
-- =============================================

CREATE PROC [dbo].[SP_userList]
  @pharmacy_id  int,
  @PageSize		int,
  @PageNumber    int,
  @SearchString  nvarchar(100)=null

	AS
   BEGIN
   DECLARE @count int=0;  

   SELECT
   U.pharmacy_user_id,
   U.pharmacy_id,
   U.first_name,
   U.middle_name,
   U.last_name,
   U.email,
   A.phone
   INTO #Temp_user
   FROM pharmacy_users U 
   JOIN address_master A
   ON U.pharmacy_user_id =A.pharmacy_user_id
   WHERE ((U.pharmacy_id=@pharmacy_id)
    AND
           (U.is_deleted != 1))
 --SELECT * FROM #Temp_user

  SELECT @count=ISNULL(COUNT(*),0) FROM #Temp_user
  WHERE  (first_name LIKE '%'+ISNULL(@SearchString,first_name)+'%' OR
  last_name LIKE '%'+ISNULL(@SearchString,last_name)+'%')

  SELECT 
  pharmacy_user_id   AS PharmacyUSerId,
  pharmacy_id		 AS PharmacyId,
  first_name +' '+ 	last_name	 AS Name, 
  email				 AS Email,
  phone				 AS Phone,
  @count			 AS Count
  From #Temp_user
  WHERE  (first_name LIKE '%'+ISNULL(@SearchString,first_name)+'%' OR
  last_name LIKE '%'+ISNULL(@SearchString,last_name)+'%')
  ORDER BY pharmacy_user_id desc
  OFFSET  @PageSize * (@PageNumber - 1)   ROWS
  FETCH NEXT @PageSize ROWS ONLY	
  
  DROP TABLE #Temp_user
  END




GO
/****** Object:  StoredProcedure [dbo].[substract_qty_from_inventory]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author : Sagar 
-- Create date: 03-07-2018
-- Description: SP to substract the qty from inventory.
--EXEC substract_qty_from_inventory
-- =============================================



CREATE PROC [dbo].[substract_qty_from_inventory]

  @pharmacyid			INT,
  @qty_to_subtract		DECIMAL(10,2),
  @ndc					BIGINT
 
  AS
   BEGIN
				 WHILE(@qty_to_subtract > 0)
					BEGIN
						DECLARE @QOH  DECIMAL(10,2);
						DECLARE @inventory_id  INT;
						 
						 SELECT  @QOH = inv_b.pack_size, @inventory_id = inv_b.inventory_id from inventory inv_b WHERE inv_b.inventory_id =
						 (SELECT TOP 1 MIN(inv_a.inventory_id) FROM inventory inv_a WHERE inv_a.ndc = @ndc AND inv_a.pharmacy_id = @pharmacyid AND inv_a.pack_size >0 AND inv_a.is_deleted = 0 )

						 	IF((@qty_to_subtract > @QOH) AND (@QOH > 0) )
								BEGIN
									Update inventory SET pack_size = 0,  is_deleted = 1 WHERE inventory_id = @inventory_id
									SET @qty_to_subtract = @qty_to_subtract - @QOH;
								END
							
							ELSE
								BEGIN
									Update inventory SET pack_size = (@QOH-@qty_to_subtract) WHERE inventory_id = @inventory_id
									SET @qty_to_subtract = @qty_to_subtract - @QOH;

								END
					END	
				
  END


















GO
/****** Object:  StoredProcedure [dbo].[Test_sp]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROC [dbo].[Test_sp]
  @id int=1
    
	AS
   BEGIN

	 SELECT  A.pharmacy_name as PharmacyName,
	 B.address_line_1 as Address,
	 'abc' TestRow
	 
	 
	  FROM [dbo].[sa_pharmacy] AS A JOIN [dbo].[sa_superAdmin_sddress] AS B 
	 ON A.pharmacy_id=B.pharmacy_id
	 
	-- RETURN @var1;

  END




GO
/****** Object:  StoredProcedure [dbo].[TransferOrderToInventory]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================
-- Author:      Sagar Sharma
-- Create date: 11-06-2018
-- Description: SP to transfer the orders to inventory table.
-- =============================================

CREATE PROCEDURE [dbo].[TransferOrderToInventory]
	(
	@orderId			int
	
	)
 AS 
 BEGIN
		DECLARE @pharmacyId      INT
		DECLARE @WholesalerId    INT

		DECLARE @OrderStatus INT
		SELECT @OrderStatus = order_status_id FROM pharmacy_order_status_master WHERE status_name='Processed'

			INSERT INTO inventory(drug_name, ndc, pack_size, price, NDC_Packsize, Strength, LotNumber, expiry_date, opened, damaged, non_c2, wholesaler_id,  pharmacy_id, inventory_source_id, created_on, is_deleted) 
			(SELECT 
					odl.drugname,
					odl.ndc,
					odl.quantity,
					odl.price,
					odl.ndc_packsize,
					odl.strength,
					odl.lot_number,
					odl.expiry_date,
					odl.opened,
					odl.damaged,
					odl.non_c2,
					od.wholesaler_id,
					od.pharmacy_id,
					3,
					GETDATE(),
					0
			  FROM orders od 
			  INNER JOIN order_details odl ON od.order_id = odl.order_id 
			  WHERE od.order_id = @orderId
			  
			 )


			 -- Update the status of order as processed after adding it to inventory table.
			 UPDATE orders SET 
					order_status_id = @OrderStatus -- Processed to inventory
			 WHERE order_id = @orderId
 
END;




GO
/****** Object:  StoredProcedure [dbo].[update_inv_after_returntoWholesaler]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author : Sagar 
-- Create date: 11-06-2018
-- Description: SP to update the inventory after returning the inventory to wholesaler.
--EXEC update_inv_after_returntoWholesaler
-- =============================================



CREATE PROC [dbo].[update_inv_after_returntoWholesaler]

  @reurntowholesalerId    INT
 
  AS
   BEGIN
		DECLARE @ph_id	INT
		
		SELECT @ph_id = pharmacy_id FROM ReturnToWholesaler WHERE returntowholesaler_Id = @reurntowholesalerId 

		CREATE TABLE  #TempReturnItems(
						ndc			BIGINT,
						qty_disp	DECIMAL(10,2),
						rowID		INT IDENTITY(1,1) 			
						)

		INSERT INTO #TempReturnItems(ndc,qty_disp)
				(SELECT ndc, quantity from return_to_wholesaler_items WHERE returntowholesaler_Id = @reurntowholesalerId )

		 DECLARE @count INT;
		 SELECT  @count= count(*) FROM #TempReturnItems

		 Declare @index INT =1;

		WHILE(@index <= @count)
			BEGIN
				DECLARE @ndc BIGINT, @qty_disp DECIMAL(10,2);

				SELECT @ndc = ndc, @qty_disp = qty_disp from #TempReturnItems WHERE rowID = @index;

				 WHILE(@qty_disp > 0)
					BEGIN
						DECLARE @QOH  INT;
						DECLARE @inventory_id  INT;
						 
						 SELECT  @QOH = inv_b.pack_size, @inventory_id = inv_b.inventory_id from inventory inv_b WHERE inv_b.inventory_id =
						 (SELECT TOP 1 MIN(inv_a.inventory_id) FROM inventory inv_a WHERE inv_a.ndc = @ndc AND inv_a.pharmacy_id = @ph_id AND inv_a.pack_size >0 AND inv_a.is_deleted = 0 )

						 	IF((@qty_disp > @QOH) AND (@QOH > 0) )
								BEGIN
									Update inventory SET pack_size = 0,  is_deleted = 1 WHERE inventory_id = @inventory_id
									SET @qty_disp = @qty_disp - @QOH;
								END
							
							ELSE
								BEGIN

									Update inventory SET pack_size = (@QOH-@qty_disp) WHERE inventory_id = @inventory_id
									SET @qty_disp = @qty_disp - @QOH;

								END
					END	
				SET @index=@index+1
			END

			DROP TABLE #TempReturnItems
			
  END


















GO
/****** Object:  StoredProcedure [dbo].[update_invAfter_shipping_order]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author : Sagar 
-- Create date: 11-06-2018
-- Description: SP to update the inventory after shipping the orders to other pharmacy.
--EXEC update_invAfter_shipping_order
-- =============================================



CREATE PROC [dbo].[update_invAfter_shipping_order]

  @shippingId    INT
 
  AS
   BEGIN
		DECLARE @SellerPH_id	INT
		--SET @shippingId =6
		
		SELECT @SellerPH_id = seller_pharmacy_id FROM shippment WHERE  shippment_id  = @shippingId

		CREATE TABLE  #TempOrderItems(
						ndc			BIGINT,
						qty_disp			DECIMAL(10,2),
						rowID		INT IDENTITY(1,1) 			
						)

		INSERT INTO #TempOrderItems(ndc,qty_disp)
				(SELECT ndc, quantity from shippmentdetails WHERE shippment_id = @shippingId)

		 DECLARE @count INT;
		 SELECT  @count= count(*) FROM #TempOrderItems

		 Declare @index INT =1;

		WHILE(@index <= @count)
			BEGIN
				DECLARE @ndc BIGINT, @qty_disp DECIMAL(10,2);

				SELECT @ndc = ndc, @qty_disp = qty_disp from #TempOrderItems WHERE rowID = @index;

				 WHILE(@qty_disp > 0)
					BEGIN
						DECLARE @QOH  DECIMAL(10,2);
						DECLARE @inventory_id  INT;
						 
						 SELECT  @QOH = inv_b.pack_size,  @inventory_id = inv_b.inventory_id from inventory inv_b WHERE inv_b.inventory_id =
						 (SELECT TOP 1 MIN(inv_a.inventory_id) FROM inventory inv_a WHERE inv_a.ndc = @ndc AND inv_a.pharmacy_id = @SellerPH_id AND inv_a.pack_size >0 AND inv_a.is_deleted = 0 )

						 	IF((@qty_disp > @QOH) AND (@QOH > 0) )
								BEGIN
									Update inventory SET pack_size = 0,  is_deleted = 1 WHERE inventory_id = @inventory_id
									SET @qty_disp = @qty_disp - @QOH;
								END
							
							ELSE
								BEGIN

									Update inventory SET pack_size = (@QOH-@qty_disp) WHERE inventory_id = @inventory_id
									SET @qty_disp = @qty_disp - @QOH;

								END
					END	
				SET @index=@index+1
			END
			DROP TABLE #TempOrderItems

  END








GO
/****** Object:  StoredProcedure [dbo].[Updateshippingdetails]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
--==============================================
-- Created by: Sagar Sharma
-- Create date: 01-06-2018
-- Description: SP to update the shippment table with shipping details
-- =============================================

CREATE PROCEDURE [dbo].[Updateshippingdetails]
(  
	@shipmentId			  INT,	
	@fromPharmacyName	  NVARCHAR(500),	
	@fromAddressline      NVARCHAR(500),
	@fromCity		      NVARCHAR(500),
	@fromStateCode	      NVARCHAR(500),
	@fromPostalCode	      NVARCHAR(500),
	@fromPhone			  NVARCHAR(100),	
	@toPharmacyName		  NVARCHAR(500),
	@toPhone			  NVARCHAR(500),
	@toAddressline		  NVARCHAR(500),
	@toCity				  NVARCHAR(500),
	@toStateCode	      NVARCHAR(500),
	@toPostalCode	      NVARCHAR(500),
	@PackageWeight		  DECIMAL(10,2),
	@shippingCost		  DECIMAL(10,2),
	@trackingNumber       NVARCHAR(500),
	@graphicImage         VARCHAR(max)	 	
)  
AS  
	BEGIN  
	IF(@trackingNumber='')
		set @trackingNumber = NULL


		UPDATE shippment SET
			fromPharmacyName =	@fromPharmacyName,
			fromAddressline =	@fromAddressline,
			fromCity =			@fromCity,
			fromStateCode =		@fromStateCode,
			fromPostalCode =    @fromPostalCode,
			from_phone	=		@fromPhone,
			toPharmacyName =	@toPharmacyName,
			toPhone =			@toPhone,
			toAddressline =		@toAddressline,
			toCity =			@toCity,
			toStateCode =		@toStateCode,
			toPostalCode =		@toPostalCode,
			package_weight=		@PackageWeight,
			shipping_cost =     @shippingCost,
			tracking_number=    @trackingNumber,
			graphic_image =     @graphicImage


			WHERE shippment_id = @shipmentId


			--Select @shipmentId




	END  


--select * from transfer_management







GO
/****** Object:  StoredProcedure [dbo].[usp_expired_products]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author:		<Author, Ankit Joshi>
-- Create date: <Create Date, 2018-04-23>
-- Description:	<stored procedure to get expired products from inventory>
--EXEC usp_expired_products 1417,10,1,''
-- =============================================
CREATE PROCEDURE [dbo].[usp_expired_products] 
	@pharmacy_id INT,
	@pageSize INT,
	@pageNumber INT,
	@searchString NVARCHAR(250) = ''
AS
BEGIN
	
	-- DECLARING SCALAR VARIABLES
	DECLARE @pharma_id INT = @pharmacy_id
	DECLARE @pgNumber INT = @pageNumber
	DECLARE @pgSize INT = @pageSize
	DECLARE @search NVARCHAR(250) = @searchString
	DECLARE @expMonth TINYINT = 0
	DECLARE @count INT = 0

	SET NOCOUNT ON;
	
	-- GET MEDICINE EXPIRY AND SET ON VARIABLE 
	SET @expMonth = (SELECT expiry_month FROM [dbo].[Inv_Exp_Config] 
	WHERE is_deleted = 0)

    -- SELECT RECORD FROM INVENTORY THAT ARE EXPIRED AND STORE IN TEMP TABLE
	SELECT * INTO 
	#EXPIRED_DRUGS
	FROM [dbo].[Inventory]
	WHERE pharmacy_id = @pharma_id AND is_deleted = 0 AND pack_size > 0
	AND EOMONTH(DATEADD(mm,+@expMonth,created_on)) < GETDATE() 

	-- GET AND SET COUNT
	 SELECT @count = ISNULL(COUNT(*),0) FROM #EXPIRED_DRUGS 
	 WHERE (drug_name LIKE '%'+ISNULL(@search,drug_name)+'%' OR   
	ndc LIKE '%'+ISNULL(@search,ndc)+'%')

	-- SELECT RECORD FROM TEMP TABLE


	 IF @PageSize > 0
	 BEGIN
		SELECT 
			inventory_id	AS InventoryId,
			pharmacy_id		AS PharmacyId,
			wholesaler_id	AS WholesalerId,
			drug_name		AS DrugName,
			ndc				AS NDC,
			pack_size		AS Quantity,
			price			AS Price,
			created_on		AS CreatedOn,
			EOMONTH(DATEADD(mm,+@expMonth,created_on)) AS ExpiryDate,
			@count			AS Count,
			strength		AS Strength
	FROM #EXPIRED_DRUGS
	WHERE (drug_name LIKE '%'+ISNULL(@search,drug_name)+'%' OR   
	ndc LIKE '%'+ISNULL(@search,ndc)+'%')
	ORDER BY inventory_id
	OFFSET  @pgSize * (@pageNumber - 1)   ROWS
	FETCH NEXT @pgSize ROWS ONLY

	END
	ELSE
	BEGIN
	 	SELECT 
			inventory_id	AS InventoryId,
			pharmacy_id		AS PharmacyId,
			wholesaler_id	AS WholesalerId,
			drug_name		AS DrugName,
			ndc				AS NDC,
			pack_size		AS Quantity,
			price			AS Price,
			created_on		AS CreatedOn,
			EOMONTH(DATEADD(mm,+@expMonth,created_on)) AS ExpiryDate,
			@count			AS Count,
			strength		AS Strength
	FROM #EXPIRED_DRUGS
	WHERE (drug_name LIKE '%'+ISNULL(@search,drug_name)+'%' OR   
	ndc LIKE '%'+ISNULL(@search,ndc)+'%')
	ORDER BY inventory_id
	
	END	 
	

	-- DROP TEMP TABLE
	DROP TABLE #EXPIRED_DRUGS
END





GO
/****** Object:  StoredProcedure [dbo].[usp_GetLiquidation]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO



-- ======================================================================================================
-- Create date: <Create Date, 20180419>
-- Description:	<Description, sp to get list of recent liquidation on basis of unused for last 3-months>
--usp_GetLiquidation 1417,100,1,''
-- ======================================================================================================

CREATE PROCEDURE [dbo].[usp_GetLiquidation]
	@pharmacyId INT,
	@pageSize INT,
	@pageNumber INT,
	@searchString NVARCHAR(50) = ''
AS
BEGIN

	 CREATE TABLE #Temp_RecommendedForReturn(		
		inventory_id	INT,
		pharmacy_id		INT,
		wholesaler_id	INT,	
		drug_name		NVARCHAR(1000),	
		ndc				BIGINT,
		QuantityOnHand	DECIMAL(10,2),
		OptimalQuantity DECIMAL(10,2),		
		price			MONEY,
		expiration_date	DATETIME,
		[opened]		BIT,
		[damaged]		BIT,
		[non_c2]		BIT,
		[created_on]	DATETIME,
		Strength		NVARCHAR(100)
	)
	
	
	INSERT INTO  #Temp_RecommendedForReturn(inventory_id, pharmacy_id,wholesaler_id,drug_name, ndc,QuantityOnHand,OptimalQuantity,price,expiration_date,opened, damaged,non_c2,created_on )
  		EXEC SP_RecommendedForReturn_rawdata @pharmacyId		 	 
		
	DECLARE @Count INT
	SELECT @Count = COUNT(*) FROM #Temp_RecommendedForReturn  WHERE (drug_name LIKE '%'+ISNULL(@searchString,drug_name)+'%'  OR 
	  ndc LIKE '%'+ISNULL(@searchString,ndc)+'%')
	

	 IF @PageSize > 0
	 BEGIN
	 SELECT 
		temp.inventory_id	AS InventoryId,
		temp.pharmacy_id		AS PharmacyId,
		temp.wholesaler_id	AS WholesalerId,
		temp.drug_name		AS DrugName,
		temp.ndc				AS NDC,
		temp.QuantityOnHand		AS Quantity,
		temp.price			AS Price,
		temp.created_on		AS CreatedOn,
		@Count				AS Count,
		inv.strength		AS Strength
	 FROM #Temp_RecommendedForReturn temp join inventory inv
	 on temp.inventory_id= inv.inventory_id
	 WHERE (temp.drug_name LIKE '%'+ISNULL(@searchString,temp.drug_name)+'%'  OR 
	  temp.ndc LIKE '%'+ISNULL(@searchString,temp.ndc)+'%')
	 ORDER BY temp.inventory_id
	 OFFSET  @pageSize * (@pageNumber - 1)   ROWS
     FETCH NEXT @pageSize ROWS ONLY

	END
	ELSE
	BEGIN
	 SELECT 
		temp.inventory_id	AS InventoryId,
		temp.pharmacy_id		AS PharmacyId,
		temp.wholesaler_id	AS WholesalerId,
		temp.drug_name		AS DrugName,
		temp.ndc				AS NDC,
		temp.QuantityOnHand		AS Quantity,
		temp.price			AS Price,
		temp.created_on		AS CreatedOn,
		@Count				AS Count,
		inv.strength		AS Strength
	 FROM #Temp_RecommendedForReturn temp join inventory inv
	 on temp.inventory_id= inv.inventory_id
	 WHERE (temp.drug_name LIKE '%'+ISNULL(@searchString,temp.drug_name)+'%'  OR 
	  temp.ndc LIKE '%'+ISNULL(@searchString,temp.ndc)+'%')
	 ORDER BY temp.inventory_id

	END	 
	
	 -- PERFORM PAGINATION & SEARCH ON TEMP TABLE #TEMP_LIQUIDATION
	
	 -- DROP TEMP TABLE
	 DROP TABLE #Temp_RecommendedForReturn
END


--exec 

--select * from inventory where pack_size like '-%'

--update inventory set pack_size='36' where inventory_id=206615



GO
/****** Object:  StoredProcedure [dbo].[usp_getTickets]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================
-- Author:		<Author, Ankit Joshi>
-- Create date: <Create Date, 2018-05-14>
-- Description:	<Description, stored procedure to get tickets raised by pharmacy>
-- =============================================

CREATE PROCEDURE [dbo].[usp_getTickets] 
	@pharmacyId INT,
	@type NVARCHAR(50) = '',
	@pagesize INT,
	@pagenumber INT,
	@searchString NVARCHAR(250) = ''
	
AS
BEGIN
	
	DECLARE @pSize INT = @pagesize
	DECLARE @pNumber INT = @pagenumber
	DECLARE @SEARCH NVARCHAR(250) = @searchString
	DECLARE @uTYPE NVARCHAR(50) = @type
	DECLARE @count INT

	-- SET NOCOUNT ON 
	SET NOCOUNT ON;

	-- CHECK CONDITION 
	-- IF TYPE IS PHARMACY THEN GET ALL THE TICKETS FOR THE SPECIFIC PHARMACY
	IF @uTYPE = 'Admin'
		BEGIN 

			SELECT *  INTO #TICKETS_TEMP_TABLE FROM TICKETS 
			WHERE Pharmacy_Id = @pharmacyId 
			AND (Problem_Definition LIKE '%'+ISNULL(@SEARCH,Problem_Definition)+'%' 
			OR TicketNumber LIKE '%'+ISNULL(@SEARCH,TicketNumber)+'%')

			-- SELECT COUNT OF RECORD
			SELECT @COUNT = ISNULL(COUNT(*),0) FROM #TICKETS_TEMP_TABLE

			-- SELECT RECORD
			SELECT 
				T.Ticket_Id As Id,
				T.TicketStatus_Id AS TicketStatusId,
				TS.Status AS TicketStatus,
				T.Pharmacy_Id AS PharmacyId,
				T.TicketNumber AS TicketNumber,
				T.Problem_Definition AS ProblemDescription,
				T.TIX_RaisedDT AS TicketRaisedDT,
				T.TIX_ResolvedDT AS TicketResolvedDT,
				T.TIX_ResolvedBY AS ResolvedBy,
				T.Remarks AS RemarkByResolver,
				T.CreatedOn As CreatedOn,
				@count AS Count
			 FROM #TICKETS_TEMP_TABLE AS T
			 INNER JOIN [dbo].[TicketStatus] AS TS
			 ON T.TicketStatus_Id = TS.Id
			 ORDER BY CreatedOn DESC
			 OFFSET  @pSize * (@pNumber - 1) ROWS
			 FETCH NEXT @pSize ROWS ONLY
	
			-- DROP TEMP TABLE 
			DROP TABLE #TICKETS_TEMP_TABLE
	END
	ELSE IF(@uTYPE = 'SuperAdmin')
		BEGIN
			SELECT * INTO #saTICKETS_TEMP_TABLE FROM TICKETS 
			WHERE (Problem_Definition LIKE '%'+ISNULL(@SEARCH,Problem_Definition)+'%' 
			OR TicketNumber LIKE '%'+ISNULL(@SEARCH,TicketNumber)+'%')
			--AND TicketStatus_Id IN (SELECT Id FROM [dbo].[TicketStatus] WHERE Status = 'Open')
			
			-- SELECT COUNT OF RECORD
			SELECT @COUNT = ISNULL(COUNT(*),0) FROM #saTICKETS_TEMP_TABLE
			
			-- SELECT RECORD
			SELECT 
				T.Ticket_Id As Id,
				T.TicketStatus_Id AS TicketStatusId,
				TS.Status AS TicketStatus,
				T.Pharmacy_Id AS PharmacyId,
				P.pharmacy_name AS PharmacyName,
				T.TicketNumber AS TicketNumber,
				T.Problem_Definition AS ProblemDescription,
				T.TIX_RaisedDT AS TicketRaisedDT,
				T.TIX_ResolvedDT AS TicketResolvedDT,
				T.TIX_ResolvedBY AS ResolvedBy,
				T.Remarks AS RemarkByResolver,
				T.CreatedOn As CreatedOn,
				@count AS Count
			 FROM #saTICKETS_TEMP_TABLE AS T
			 INNER JOIN [dbo].[TicketStatus] AS TS
			 ON T.TicketStatus_Id = TS.Id
			 INNER JOIN [dbo].[pharmacy_list] AS P
			 ON T.Pharmacy_Id = P.pharmacy_id
			 where P.is_deleted = 0
			 ORDER BY CreatedOn DESC
			 OFFSET  @pSize * (@pNumber - 1) ROWS
			 FETCH NEXT @pSize ROWS ONLY

			-- DROP TEMP TABLE 
			DROP TABLE #saTICKETS_TEMP_TABLE
		END
END



GO
/****** Object:  StoredProcedure [dbo].[usp_InDateReurnWHL]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================================================
-- Author:		<Author, Ankit Joshi>
-- Create date: <Create Date, 2018-04-19>

-- Description:	<sp to get List of in date return to wholesaler 
				-- criteria to meet for sp to give result 
				--> 1: item unused for 3 months
				--> 2: fulfilling criteria of item return to wholesaler
				--> 3: expiry date greater than 10 months 
				-->
-- =============================================================================
CREATE PROCEDURE [dbo].[usp_InDateReurnWHL]  
	-- Add the parameters for the stored procedure here
	@pharmacy_id INT,
	@pageSize INT,
	@pageNumber INT,
	@searchString NVARCHAR(250) = ''
AS
BEGIN
	
	DECLARE @expired_month INT
	SELECT @expired_month = [expiry_month] FROM [Inv_Exp_Config]

	SET NOCOUNT ON;
	 
	 -- SCALAR VARIABLE
	 DECLARE @pharmaId INT = @pharmacy_id
	 DECLARE @pSize INT = @pageSize
	 DECLARE @pNumber INT = @pageNumber
	 DECLARE @search NVARCHAR(250) = @searchString
	 DECLARE @count INT
	 DECLARE @recomended_qty FLOAT = 0.0
	 DECLARE @extended_qty FLOAT = 0.0

	
	 -- FETCH ALL THE RECORD'S FROM RX30 TABLE THAT ARE NOT GETTING SOLD IN LAST 3 MONTH FROM CURRENT DATE
	 SELECT ndc,MAX(created_on) AS LAST_SOLD INTO #ELIGIBLE_LIQ 
	 FROM [inviewanalytics].[dbo].[RX30_inventory]
	 WHERE pharmacy_id = @pharmaId
	 GROUP BY ndc 
	 HAVING MAX(created_on) <= DateAdd(mm,-3,getdate())

	 -- FETCH RECORD FROM INVENTORY TABLE FOR THE USE CASES AND STORE IN TEMP TABLE:
		-- CASE 1 #ELIGIBLE_LIQ TABLE containing not sold for 3 months
		-- CASE 2 expiry date is more than 6 months
		-- CASE 3 NOT DAMAGED
	 
	 SELECT * INTO #TEMP_LIQUIDATION
	 FROM [dbo].[inventory] 
	 WHERE ndc IN (SELECT ndc from #ELIGIBLE_LIQ) 
	 AND pharmacy_id = 1417--@pharmaId
	 --AND DATEDIFF(mm,GETDATE(),DATEADD(mm,+10,created_on)) > @expired_month
	AND ( GETDATE() > DATEADD(month, 10 , EOMONTH(DATEADD(month, @expired_month ,created_on))) )  /*Must be greater than 10 month expiration dating*/

	 -- DROP TEMP TABLE HOLDING NDC
	 DROP TABLE #ELIGIBLE_LIQ

	 -- COUNT
	 SELECT @count = ISNULL(COUNT(*),0) FROM #TEMP_LIQUIDATION
	
	-- SELECT DATA FROM TEMP TABLE WITH PAGING AND SEARCHING
	SELECT 
			inventory_id	AS InventoryId,
			pharmacy_id		AS PharmacyId,
			wholesaler_id	AS WholesalerId,
			drug_name		AS DrugName,
			ndc				AS NDC,
			pack_size		AS Quantity,
			price			AS Price,
			@Count          AS Count,
			@recomended_qty AS Recomended_QTY,
			@extended_qty   AS Extended_QTY
		FROM #TEMP_LIQUIDATION
		WHERE (drug_name LIKE '%'+ISNULL(@search,drug_name)+'%' OR   
		ndc LIKE '%'+ISNULL(@search,ndc)+'%')
		ORDER BY inventory_id
		OFFSET  @pSize * (@pNumber - 1)   ROWS
		FETCH NEXT @pSize ROWS ONLY
		-- NEED TO ADD CONDITION IN WHERE CLAUSE FOR IS DAMAGED 
		-- NEED TO ADD CONDITION IN WHERE CLAUSE FOR IS OPENED
		-- NEED TO ADD CONDITION IN WHERE CLAUSE FOR IS NON C2 

	-- DROP TEMP TABLE
	DROP TABLE #TEMP_LIQUIDATION
END

--exec usp_InDateReurnWHL 1417,4,1,''





GO
/****** Object:  StoredProcedure [dbo].[usp_inv_pendingOrders]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author:		<Author, Ankit Joshi>
-- Create date: <Create Date, 31-05-2018>
-- Description:	<Description, user defined stored procedure to get pending orders for a invoice>
-- =============================================
CREATE PROCEDURE [dbo].[usp_inv_pendingOrders] 
	-- Add the parameters for the stored procedure here
	@pharmacy_id INT,
	@page_size INT,
	@page_number INT,
	@search_string NVARCHAR(250) = ''
AS
BEGIN
	-- SET NOCOUNT ON 
	SET NOCOUNT ON;

	-- DECLARE VARIABLES
	DECLARE @pharma_Id INT = @pharmacy_id
	DECLARE @pSize INT = @page_size
	DECLARE @pNumber INT = @page_number
	DECLARE @search NVARCHAR(250) = @search_string
	DECLARE @count INT

	-- select from invoice
	SELECT 
		count(INV.invoice_number) as InvoiceNumberGRPCount,
		inv.[invoice_number],inv.[invoice_date],inv.[purchase_order_number],
		sum(cast(itm.[invoiced_quantity] as int)) invoiceQTY, 
		sum(cast(remaining.[remaining_quantity] as int)) remainingQTY,
		sum(cast(lineitem.QtyOrdered as int)) QTYOrdered,
		sum(cast(ack.[QTY] as int)) QtyReceived
		--ITM.item_order_status,
		--INV.pharmacy_id
		INTO #PENDING_ORDER_GRP
	from invoice as inv
	inner join [dbo].[invoice_line_items] itm 
	on inv.[invoice_id] = itm.invoice_id
	inner join [dbo].[invoice_additionalItem] remaining
	on itm.[invoice_lineitem_id] = remaining.[invoice_items_id]
	inner join [dbo].[Ack_BAK_PurchaseOrder] bak
	on inv.[purchase_order_number] = bak.[PurchaseOrderNumber]
	inner join [dbo].[Ack_LineItem] lineitem
	on bak.BAK_ID = lineitem.[BAK_ID]
	inner join [dbo].[Ack_LineItemACK] ack
	on lineitem.[LineItem_ID] = ack.[LineItem_ID]
	where inv.is_deleted = 0 AND
	inv.pharmacy_id = @pharma_Id
	AND (ISNULL(INV.is_deleted,0) = 0)
	AND (INV.invoice_number LIKE '%'+ISNULL(@search,INV.invoice_number)+'%' OR   
	CAST(INV.invoice_date AS DATE) LIKE '%'+ISNULL(@search,INV.invoice_date)+'%') 

	AND ack.[StatusCode] in ('IB','IR','IW','IQ')
	group by inv.[invoice_number],inv.[invoice_date],inv.[purchase_order_number],lineitem.[BAK_ID]


	-- COUNT THE NUMBER OF RECORDS IN TEMP TABLE
	SELECT @count = ISNULL(COUNT(*),0) FROM #PENDING_ORDER_GRP

	-- SELECT RECORD FROM TEMPORARY TABLE
	SELECT 
		invoice_number			 AS Invoice_Number,
		invoice_date			 AS Invoice_Date,
		invoiceQTY				 AS InvoicedQTY,
		remainingQTY			 AS RemainingQTY,
		purchase_order_number    AS PurchaseOrderNumber,
		QTYOrdered				 AS QuantityOrdered,
		QtyReceived				 AS QuantityReceived,
		@count					 AS Count
	FROM #PENDING_ORDER_GRP
	ORDER BY invoice_date DESC
	OFFSET  @pSize * (@pNumber - 1) ROWS
	FETCH NEXT @pSize ROWS ONLY

	-- DROP TEMPORARY TABLE
	DROP TABLE #PENDING_ORDER_GRP

END





GO
/****** Object:  StoredProcedure [dbo].[usp_inv_pendingOrders_backup25062018]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author:		<Author, Ankit Joshi>
-- Create date: <Create Date, 31-05-2018>
-- Description:	<Description, user defined stored procedure to get pending orders for a invoice>
-- =============================================
CREATE PROCEDURE [dbo].[usp_inv_pendingOrders_backup25062018] 
	-- Add the parameters for the stored procedure here
	@pharmacy_id INT,
	@page_size INT,
	@page_number INT,
	@search_string NVARCHAR(250) = ''
AS
BEGIN
	-- SET NOCOUNT ON 
	SET NOCOUNT ON;

	-- DECLARE VARIABLES
	DECLARE @pharma_Id INT = @pharmacy_id
	DECLARE @pSize INT = @page_size
	DECLARE @pNumber INT = @page_number
	DECLARE @search NVARCHAR(250) = @search_string
	DECLARE @count INT

	-- select from invoice
	SELECT 
		count(INV.invoice_number) as InvoiceNumberGRPCount,
		INV.invoice_number,
		INV.invoice_date,
		INV.purchase_order_number,
		sum(cast(IT1.invoiced_quantity as int)) as InvoicedQuantity, 
		sum(cast(ITM.remaining_quantity as int)) as RemainingQuantity
		--ITM.item_order_status,
		--INV.pharmacy_id
		INTO #PENDING_ORDER_GRP
	FROM [dbo].[invoice_additionalItem] AS ITM
	INNER JOIN 
	[dbo].[invoice_line_items] AS IT1
	ON ITM.invoice_items_id = IT1.invoice_lineitem_id
	INNER JOIN 
	[dbo].[invoice] AS INV
	ON IT1.invoice_id = INV.invoice_id
	WHERE pharmacy_id = @pharma_Id
	AND (ISNULL(INV.is_deleted,0) = 0)
	AND (INV.invoice_number LIKE '%'+ISNULL(@search,INV.invoice_number)+'%' OR   
	CAST(INV.invoice_date AS DATE) LIKE '%'+ISNULL(@search,INV.invoice_date)+'%')  
	GROUP BY INV.invoice_number,INV.invoice_date,INV.purchase_order_number

	-- COUNT THE NUMBER OF RECORDS IN TEMP TABLE
	SELECT @count = ISNULL(COUNT(*),0) FROM #PENDING_ORDER_GRP

	-- SELECT RECORD FROM TEMPORARY TABLE
	SELECT 
		invoice_number			 AS Invoice_Number,
		invoice_date			 AS Invoice_Date,
		InvoicedQuantity		 AS InvoicedQTY,
		RemainingQuantity		 AS RemainingQTY,
		purchase_order_number    AS PurchaseOrderNumber,
		@count					 AS Count
	FROM #PENDING_ORDER_GRP
	ORDER BY invoice_date DESC
	OFFSET  @pSize * (@pNumber - 1) ROWS
	FETCH NEXT @pSize ROWS ONLY

	-- DROP TEMPORARY TABLE
	DROP TABLE #PENDING_ORDER_GRP

END



GO
/****** Object:  StoredProcedure [dbo].[usp_inv_pendingOrdersBACKUP712019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author:		<Author, Ankit Joshi>
-- Create date: <Create Date, 31-05-2018>
-- Description:	<Description, user defined stored procedure to get pending orders for a invoice>
-- =============================================
CREATE PROCEDURE [dbo].[usp_inv_pendingOrdersBACKUP712019]
	-- Add the parameters for the stored procedure here
	@pharmacy_id INT,
	@page_size INT,
	@page_number INT,
	@search_string NVARCHAR(250) = ''
AS
BEGIN
	-- SET NOCOUNT ON 
	SET NOCOUNT ON;

	-- DECLARE VARIABLES
	DECLARE @pharma_Id INT = @pharmacy_id
	DECLARE @pSize INT = @page_size
	DECLARE @pNumber INT = @page_number
	DECLARE @search NVARCHAR(250) = @search_string
	DECLARE @count INT

	-- select from invoice
	SELECT 
		count(INV.invoice_number) as InvoiceNumberGRPCount,
		inv.[invoice_number],inv.[invoice_date],inv.[purchase_order_number],
		sum(cast(itm.[invoiced_quantity] as int)) invoiceQTY, 
		sum(cast(remaining.[remaining_quantity] as int)) remainingQTY,
		sum(cast(lineitem.QtyOrdered as int)) QTYOrdered,
		sum(cast(ack.[QTY] as int)) QtyReceived
		--ITM.item_order_status,
		--INV.pharmacy_id
		INTO #PENDING_ORDER_GRP
	from invoice as inv
	inner join [dbo].[invoice_line_items] itm 
	on inv.[invoice_id] = itm.invoice_id
	inner join [dbo].[invoice_additionalItem] remaining
	on itm.[invoice_lineitem_id] = remaining.[invoice_items_id]
	inner join [dbo].[Ack_BAK_PurchaseOrder] bak
	on inv.[purchase_order_number] = bak.[PurchaseOrderNumber]
	inner join [dbo].[Ack_LineItem] lineitem
	on bak.BAK_ID = lineitem.[BAK_ID]
	inner join [dbo].[Ack_LineItemACK] ack
	on lineitem.[LineItem_ID] = ack.[LineItem_ID]
	where inv.is_deleted = 0 AND
	inv.pharmacy_id = @pharma_Id
	AND (ISNULL(INV.is_deleted,0) = 0)
	AND (INV.invoice_number LIKE '%'+ISNULL(@search,INV.invoice_number)+'%' OR   
	CAST(INV.invoice_date AS DATE) LIKE '%'+ISNULL(@search,INV.invoice_date)+'%') 
	AND ack.[StatusCode] in ('IB','IR','IW','IQ')
	group by inv.[invoice_number],inv.[invoice_date],inv.[purchase_order_number],lineitem.[BAK_ID]


	-- COUNT THE NUMBER OF RECORDS IN TEMP TABLE
	SELECT @count = ISNULL(COUNT(*),0) FROM #PENDING_ORDER_GRP

	-- SELECT RECORD FROM TEMPORARY TABLE
	SELECT 
		invoice_number			 AS Invoice_Number,
		invoice_date			 AS Invoice_Date,
		invoiceQTY				 AS InvoicedQTY,
		remainingQTY			 AS RemainingQTY,
		purchase_order_number    AS PurchaseOrderNumber,
		QTYOrdered				 AS QuantityOrdered,
		QtyReceived				 AS QuantityReceived,
		@count					 AS Count
	FROM #PENDING_ORDER_GRP
	ORDER BY invoice_date DESC
	OFFSET  @pSize * (@pNumber - 1) ROWS
	FETCH NEXT @pSize ROWS ONLY

	-- DROP TEMPORARY TABLE
	DROP TABLE #PENDING_ORDER_GRP

END



GO
/****** Object:  StoredProcedure [dbo].[usp_inv_pendingOrdersChangesBackup712019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =============================================
-- Author:		<Author, Ankit Joshi>
-- Create date: <Create Date, 31-05-2018>
-- Description:	<Description, user defined stored procedure to get pending orders for a invoice>
-- Updated By: <Author, Nishi Zanwar>
-- Updated date: <Updated date, 07-01-2019>
-- Description: <Changes for duplicate invoice id>
-- =============================================
CREATE PROCEDURE [dbo].[usp_inv_pendingOrdersChangesBackup712019] 
	-- Add the parameters for the stored procedure here
	@pharmacy_id INT,
	@page_size INT,
	@page_number INT,
	@search_string NVARCHAR(250) = ''
AS
BEGIN
	-- SET NOCOUNT ON 
	SET NOCOUNT ON;

	-- DECLARE VARIABLES
	DECLARE @pharma_Id INT = @pharmacy_id
	DECLARE @pSize INT = @page_size
	DECLARE @pNumber INT = @page_number
	DECLARE @search NVARCHAR(250) = @search_string
	DECLARE @count INT
	DECLARE @firstinvoiceId INT
	/*Begin: 07/01/2019: Nishi Z
	We were getting duplicate invoice id and that were showing wrong sum, so added this part*/
    set @firstinvoiceId = (select top 1 invoice_id from invoice INV where
	(ISNULL(INV.is_deleted,0) = 0)
	AND (INV.invoice_number LIKE '%'+ISNULL(@search,INV.invoice_number)+'%'))
	/*End: 07/01/2019: Nishi Z*/
	-- select from invoice
	SELECT 
		count(INV.invoice_number) as InvoiceNumberGRPCount,
		inv.[invoice_number],inv.[invoice_date],inv.[purchase_order_number],
		sum(cast(itm.[invoiced_quantity] as int)) invoiceQTY, 
		sum(cast(remaining.[remaining_quantity] as int)) remainingQTY,
		sum(cast(lineitem.QtyOrdered as int)) QTYOrdered,
		sum(cast(ack.[QTY] as int)) QtyReceived
		--ITM.item_order_status,
		--INV.pharmacy_id
		INTO #PENDING_ORDER_GRP
	from invoice as inv
	inner join [dbo].[invoice_line_items] itm 
	on inv.[invoice_id] = itm.invoice_id
	inner join [dbo].[invoice_additionalItem] remaining
	on itm.[invoice_lineitem_id] = remaining.[invoice_items_id]
	inner join [dbo].[Ack_BAK_PurchaseOrder] bak
	on inv.[purchase_order_number] = bak.[PurchaseOrderNumber]
	inner join [dbo].[Ack_LineItem] lineitem
	on bak.BAK_ID = lineitem.[BAK_ID]
	inner join [dbo].[Ack_LineItemACK] ack
	on lineitem.[LineItem_ID] = ack.[LineItem_ID]
	where inv.is_deleted = 0 AND
	inv.pharmacy_id = @pharma_Id
	/*Begin: 07/01/2019: Nishi Z*/
	AND (ISNULL(INV.invoice_id,0) = @firstinvoiceId )
	--CAST(INV.invoice_date AS DATE) LIKE '%'+ISNULL(@search,INV.invoice_date)+'%')
	/*End: 07/01/2019: Nishi Z*/
	AND ack.[StatusCode] in ('IB','IR','IW','IQ')
	group by inv.[invoice_number],inv.[invoice_date],inv.[purchase_order_number],lineitem.[BAK_ID]


	-- COUNT THE NUMBER OF RECORDS IN TEMP TABLE
	SELECT @count = ISNULL(COUNT(*),0) FROM #PENDING_ORDER_GRP

	-- SELECT RECORD FROM TEMPORARY TABLE
	SELECT 
		invoice_number			 AS Invoice_Number,
		invoice_date			 AS Invoice_Date,
		invoiceQTY				 AS InvoicedQTY,
		remainingQTY			 AS RemainingQTY,
		purchase_order_number    AS PurchaseOrderNumber,
		QTYOrdered				 AS QuantityOrdered,
		QtyReceived				 AS QuantityReceived,
		@count					 AS Count
	FROM #PENDING_ORDER_GRP
	ORDER BY invoice_date DESC
	OFFSET  @pSize * (@pNumber - 1) ROWS
	FETCH NEXT @pSize ROWS ONLY

	-- DROP TEMPORARY TABLE
	DROP TABLE #PENDING_ORDER_GRP

END



GO
/****** Object:  StoredProcedure [dbo].[usp_Invoice_Details]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:		<Author,,Ankit Joshi>
-- Create date: <Create Date,,2018-06-13>
-- Description:	<Description,,sp to get invoice details based on invoice number>
-- exec usp_Invoice_Details 1417,'938158226',10,1,''
-- =============================================
CREATE PROCEDURE [dbo].[usp_Invoice_Details] 
	-- Add the parameters for the stored procedure here
	@pharmacy_id INT,
	@invoice_number nvarchar(250),
	@pageSize INT,
	@pageNumber INT,
	@searchString NVARCHAR(250) = ''
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

    -- DECLARE VARIABLES

	DECLARE @pharmaId INT = @pharmacy_id
	DECLARE @invNum NVARCHAR(250) = @invoice_number
	DECLARE @pSize INT = @pageSize
	DECLARE @pNumber INT = @pageNumber
	DECLARE @search NVARCHAR(250) = @searchString
	DECLARE @count INT


    SELECT	INV.invoice_id,
			INV.pharmacy_id,
			INV.invoice_number,
			INV.invoice_date,
			INV.monetary_amount,
			INV.[status],
			ITM.ndc_upc,
			ITM.unit_price,
			ITM.invoiced_quantity,
			PDESC.product_desc,
			sac.sac_indicator,
			sac.sac_amount,
			sac.sac_code,
			sac.sac_description,
			TAX.tax_type,
			TAX.tax_monetory_amount
			INTO #TEMP_INVOICE_DETAIL
	 FROM [dbo].[invoice] AS INV
	 INNER JOIN [dbo].[invoice_line_items] AS ITM
	 ON INV.invoice_id = ITM.invoice_id
	 LEFT JOIN [dbo].[invoice_taxes] AS TAX
	 ON INV.invoice_id = TAX.invoice_id
	 INNER JOIN [dbo].[invoice_productDescription] AS PDESC
	 ON ITM.invoice_lineitem_id = PDESC.invoice_items_id
	 LEFT JOIN [dbo].[invoice_SAC] AS sac
	 ON ITM.invoice_lineitem_id = sac.invoice_items_id
	 WHERE INV.pharmacy_id = @pharmaId 
	 AND INV.invoice_number like '%'+@invNum+'%' 
	 AND (INV.invoice_number LIKE '%'+ISNULL(@search,INV.invoice_number)+'%' OR   
	 ITM.ndc_upc LIKE '%'+ISNULL(@search,ITM.ndc_upc)+'%')

	 -- COUNT NUMBER OF RECORD EXIST IN DATABASE
	SELECT @count = ISNULL(COUNT(*),0) FROM #TEMP_INVOICE_DETAIL

	SELECT 
	invoice_id AS InvoiceId,
	pharmacy_id AS PharmacyId,
	invoice_number AS InvoiceNum,
	invoice_date AS InvoiceDate,
	monetary_amount AS MonetaryAmount,
	[STATUS] AS InvStatus,
	ndc_upc AS NDC,
	unit_price AS UNITPRICE,
	invoiced_quantity AS INVQTY,
	product_desc AS DrugName,
	sac_indicator AS sacIndicator,
	sac_amount AS SacAmount,
	sac_code AS SacCode,
	sac_description AS SacDescription,
	tax_type AS TaxType,
	tax_monetory_amount AS TaxAmount,
	@count AS [COUNT]
	FROM #TEMP_INVOICE_DETAIL
	ORDER BY invoice_date DESC
	OFFSET @pSize *(@pNumber - 1) ROWS
	FETCH NEXT @pSize ROWS ONLY

	-- DROP TEMP TABLE
	DROP TABLE #TEMP_INVOICE_DETAIL

END


GO
/****** Object:  StoredProcedure [dbo].[usp_invoice_tracking]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =====================================================================
-- Author:		<Author, ANKIT JOSHI>
-- Create date: <Create Date, 2018-04-27>
-- Description:	<USER STORED PROCEDURE TO GET THE INVOICE DETAILS>
--EXEC usp_invoice_tracking 13,10,1,''
--Updated: Prashant W - To show medicine name from dba database
--Updated Date: 01-04-2019

-- ======================================================================



CREATE PROCEDURE [dbo].[usp_invoice_tracking] 
	@pharmacy_id	INT,
	@pageSize		INT,
	@pageNumber		INT,
	@searchString	NVARCHAR(250) = ''
AS
BEGIN

	SET NOCOUNT ON;
    -- DECLARE VARIABLES

	DECLARE @pharmaId INT = @pharmacy_id
	DECLARE @pSize INT = @pageSize
	DECLARE @pNumber INT = @pageNumber
	DECLARE @search NVARCHAR(250) = @searchString
	DECLARE @count INT

	
	SELECT	INV.invoice_id,INV.invoice_number,INV.pharmacy_id,INV.monetary_amount,INV.invoice_date,INV.[status],
			ITM.ndc_upc,			
			ITM.unit_price,
			ITM.invoiced_quantity,
			PDESC.product_desc,
			SDESC.shipto_name
		INTO #TEMP_INVOICE
	 FROM [dbo].[invoice] AS INV
		INNER JOIN [dbo].[invoice_line_items] AS ITM
				ON INV.invoice_id = ITM.invoice_id

		INNER JOIN [dbo].[invoice_productDescription] AS PDESC
			ON ITM.invoice_lineitem_id = PDESC.invoice_items_id

		INNER JOIN [dbo].[invoice_shipping_details] AS SDESC

			ON INV.invoice_id = SDESC.invoice_id

	 WHERE INV.pharmacy_id = @pharmaId
		AND INV.is_deleted =0
		AND (PDESC.product_desc LIKE '%'+ISNULL(@search,PDESC.product_desc)+'%' OR   
			 ITM.ndc_upc LIKE '%'+ISNULL(@search,ITM.ndc_upc)+'%')



	-- COUNT NUMBER OF RECORD EXIST IN DATABASE

	SELECT @count = ISNULL(COUNT(*),0) FROM #TEMP_INVOICE

	

	DECLARE @Sum_Qty DECIMAL(10,2)

	SELECT @Sum_Qty = sum(CONVERT(DECIMAL(10,2),replace(invoiced_quantity, ',', ''))) from #TEMP_INVOICE

	/*Update medicine name as it show c1,c2 at the beggining of name*/
		ALTER TABLE #TEMP_INVOICE ALTER COLUMN product_desc nvarchar(2000) NOT NULL;
		
		UPDATE TMP_INV
			--SET TMP_INV.product_desc = drug_name
			SET TMP_INV.product_desc = fdb_prd.NONPROPRIETARYNAME
		FROM #TEMP_INVOICE TMP_INV
		--INNER JOIN inventory inv ON inv.ndc = TMP_INV.ndc_upc
			INNER JOIN  [dbo].[FDB_Package] fdb_pkg	ON fdb_pkg.NDCINT = CAST(TMP_INV.ndc_upc AS BIGINT)
			INNER JOIN [dbo].[FDB_Product] fdb_prd ON fdb_prd.PRODUCTID =  fdb_pkg.PRODUCTID
	
	-- SELECT RECORD FROM TEMP TABLE

	 IF @PageSize > 0
	 BEGIN
		SELECT 
				invoice_id AS Invoice_id,
				invoice_number AS Invoice_Num,
				pharmacy_id AS Pharmacy_Id,
				monetary_amount AS Total_Amount,
				CAST(ndc_upc AS BIGINT) AS NDC_Codes,
				@count AS [COUNT],
				unit_price AS Price_Per_Unit,	
				invoiced_quantity  AS Quantity,
				product_desc AS DrugName,
				shipto_name AS ShippedTo,
				invoice_date AS InvoiceDate,
				[status] AS InStatus,	
				@Sum_Qty  AS QtySum
			FROM #TEMP_INVOICE
			ORDER BY invoice_date DESC
			OFFSET @pageSize *(@pageNumber - 1) ROWS
			FETCH NEXT @pageSize ROWS ONLY

	END
	ELSE
	BEGIN
		SELECT 
			invoice_id AS Invoice_id,
			invoice_number AS Invoice_Num,
			pharmacy_id AS Pharmacy_Id,
			monetary_amount AS Total_Amount,
			CAST(ndc_upc AS BIGINT) AS NDC_Codes,
			@count AS [COUNT],
			unit_price AS Price_Per_Unit,	
			invoiced_quantity  AS Quantity,
			product_desc AS DrugName,
			shipto_name AS ShippedTo,
			invoice_date AS InvoiceDate,
			[status] AS InStatus,	
			@Sum_Qty  AS QtySum
		FROM #TEMP_INVOICE
		ORDER BY invoice_date DESC
			
	END	 

	
	DROP TABLE #TEMP_INVOICE



END



GO
/****** Object:  StoredProcedure [dbo].[usp_invoice_tracking_backup20180613]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- =====================================================================

-- Author:		<Author, ANKIT JOSHI>

-- Create date: <Create Date, 2018-04-27>

-- Description:	<USER STORED PROCEDURE TO GET THE INVOICE DETAILS>

--EXEC usp_invoice_tracking_backup20180613 1417,10,1,''

-- ======================================================================

CREATE PROCEDURE [dbo].[usp_invoice_tracking_backup20180613] 

	@pharmacy_id INT,

	@pageSize INT,

	@pageNumber INT,

	@searchString NVARCHAR(250) = ''

AS

BEGIN

	-- SET NO COUNT 

	SET NOCOUNT ON;

    -- DECLARE VARIABLES

	DECLARE @pharmaId INT = @pharmacy_id

	DECLARE @pSize INT = @pageSize

	DECLARE @pNumber INT = @pageNumber

	DECLARE @search NVARCHAR(250) = @searchString

	DECLARE @count INT

	-- SELECT INVOICE DETAILS --
	SELECT 
		INV.invoice_id,
		INV.INVOICE_NUMBER, 
		INV.INVOICE_DATE,
		INV.PURCHASE_ORDER_NUMBER,
		INV.INVOICED_LINEITEM,
		INV.SHIPPED_LINEITEMS,
		ISD.SAP_NUMBER,
		ISD.SHIPTO_NAME,
		INV.[STATUS],
		INV.pharmacy_id
		INTO #TEMP_INVOICE
	FROM INVOICE INV
	INNER JOIN INVOICE_SHIPPING_DETAILS ISD 
	ON 
	INV.INVOICE_ID = ISD.INVOICE_ID
	WHERE INV.pharmacy_id = @pharmaId
	AND (INV.INVOICE_NUMBER LIKE '%'+ISNULL(@search,INV.INVOICE_NUMBER)+'%')
	--GROUP BY INV.INVOICE_NUMBER
	--HAVING COUNT(INV.INVOICE_NUMBER) > 1

	-- COUNT NUMBER OF RECORD EXIST IN DATABASE
	SELECT @count = ISNULL(COUNT(*),0) FROM #TEMP_INVOICE


	-- SELECT RECORD FROM TEMP TABLE

	SELECT 
	invoice_id AS InvoiceId,
	INVOICE_NUMBER AS InvoiceNum,
	INVOICE_DATE AS InvoiceDate,
	PURCHASE_ORDER_NUMBER AS PurchaseOrderNumber,
	INVOICED_LINEITEM AS InvNumOfLineItems,
	SHIPPED_LINEITEMS AS ShippedQTY,
	SHIPTO_NAME AS ShippedTo,
	SAP_NUMBER as SapNumber,
	[STATUS] AS InStatus,
	pharmacy_id AS PharmacyId,
	@count AS [COUNT]
	FROM #TEMP_INVOICE
	ORDER BY invoice_date DESC
	OFFSET @pageSize *(@pageNumber - 1) ROWS
	FETCH NEXT @pageSize ROWS ONLY

	-- DROP TEMP TABLE

	DROP TABLE #TEMP_INVOICE

	 

	 -- NOTE : FOR ITEMS HAVING 0:00 UNIT PRICE & INVOICED QUANTITY 0

	 -- CHECK FOR ADDITIONAL ITEMS TABLE TO CHECK FOR DIFFERENCE BTW ORDERED AND SHIPPED QUANTITY

END

---------------



--Select Top 10 * from [dbo].[invoice]

--order by [invoice_id] desc





GO
/****** Object:  StoredProcedure [dbo].[usp_invoice_tracking_bk1042019]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO









-- =====================================================================



-- Author:		<Author, ANKIT JOSHI>



-- Create date: <Create Date, 2018-04-27>



-- Description:	<USER STORED PROCEDURE TO GET THE INVOICE DETAILS>



--EXEC usp_invoice_tracking 1417,10,1,''



-- ======================================================================



CREATE PROCEDURE [dbo].[usp_invoice_tracking_bk1042019] 



	@pharmacy_id INT,



	@pageSize INT,



	@pageNumber INT,



	@searchString NVARCHAR(250) = ''



AS



BEGIN



	-- SET NO COUNT 



	SET NOCOUNT ON;



    -- DECLARE VARIABLES



	DECLARE @pharmaId INT = @pharmacy_id



	DECLARE @pSize INT = @pageSize



	DECLARE @pNumber INT = @pageNumber



	DECLARE @search NVARCHAR(250) = @searchString



	DECLARE @count INT



	SELECT	INV.invoice_id,INV.invoice_number,INV.pharmacy_id,INV.monetary_amount,INV.invoice_date,INV.[status],



			ITM.ndc_upc,

			

			ITM.unit_price,



			ITM.invoiced_quantity,



			PDESC.product_desc,



			SDESC.shipto_name



			INTO #TEMP_INVOICE



	 FROM [dbo].[invoice] AS INV



	 INNER JOIN [dbo].[invoice_line_items] AS ITM



	 ON INV.invoice_id = ITM.invoice_id



	 INNER JOIN [dbo].[invoice_productDescription] AS PDESC



	 ON ITM.invoice_lineitem_id = PDESC.invoice_items_id



	 INNER JOIN [dbo].[invoice_shipping_details] AS SDESC



	 ON INV.invoice_id = SDESC.invoice_id



	 WHERE INV.pharmacy_id = @pharmaId
	  AND INV.is_deleted =0


	 AND (PDESC.product_desc LIKE '%'+ISNULL(@search,PDESC.product_desc)+'%' OR   



	 ITM.ndc_upc LIKE '%'+ISNULL(@search,ITM.ndc_upc)+'%')



	-- COUNT NUMBER OF RECORD EXIST IN DATABASE



	SELECT @count = ISNULL(COUNT(*),0) FROM #TEMP_INVOICE

	

	DECLARE @Sum_Qty DECIMAL(10,2)

	SELECT @Sum_Qty = sum(CONVERT(DECIMAL(10,2),replace(invoiced_quantity, ',', ''))) from #TEMP_INVOICE



	-- SELECT RECORD FROM TEMP TABLE

	 IF @PageSize > 0
	 BEGIN
		SELECT 
	invoice_id AS Invoice_id,
	invoice_number AS Invoice_Num,
	pharmacy_id AS Pharmacy_Id,
	monetary_amount AS Total_Amount,
	CAST(ndc_upc AS BIGINT) AS NDC_Codes,
	@count AS [COUNT],
	unit_price AS Price_Per_Unit,	
	invoiced_quantity  AS Quantity,
	product_desc AS DrugName,
	shipto_name AS ShippedTo,
	invoice_date AS InvoiceDate,
	[status] AS InStatus,	
	@Sum_Qty  AS QtySum
	FROM #TEMP_INVOICE
	ORDER BY invoice_date DESC
	OFFSET @pageSize *(@pageNumber - 1) ROWS
	FETCH NEXT @pageSize ROWS ONLY

	END
	ELSE
	BEGIN
	SELECT 
	invoice_id AS Invoice_id,
	invoice_number AS Invoice_Num,
	pharmacy_id AS Pharmacy_Id,
	monetary_amount AS Total_Amount,
	CAST(ndc_upc AS BIGINT) AS NDC_Codes,
	@count AS [COUNT],
	unit_price AS Price_Per_Unit,	
	invoiced_quantity  AS Quantity,
	product_desc AS DrugName,
	shipto_name AS ShippedTo,
	invoice_date AS InvoiceDate,
	[status] AS InStatus,	
	@Sum_Qty  AS QtySum
	FROM #TEMP_INVOICE
	ORDER BY invoice_date DESC
			
	END	 

	
	DROP TABLE #TEMP_INVOICE



END



GO
/****** Object:  StoredProcedure [dbo].[usp_itemsReturnHistory]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO



-- =============================================================================================
-- Author:		<Author, Ankit Joshi>
-- Create date: <Create Date,2018-04-19>
-- Description:	<sp to get history of invetory which is returned to wholesaler>
--exec usp_itemsReturnHistory 1417,10,1,''
-- ==============================================================================================

CREATE PROCEDURE [dbo].[usp_itemsReturnHistory] 
	@pharmacyId int,
	@pageSize int,
	@pageNumber int,
	@searchString nvarchar(200) = ''
AS
BEGIN
	
	SET NOCOUNT ON;
	
	DECLARE @pharmaId INT = @pharmacyId
	DECLARE @pSize INT = @pageSize
	DECLARE @pNumber INT = @pageNumber
	DECLARE @search NVARCHAR(200) = @searchString
	DECLARE @count INT
	
	-- SELECT INVENTORY ID FOR INSERTED PHARMACY ID AND FETCH INVENTORY DATA TO TEMP TABLE
	SELECT 
		* into #TEMP_RET_HIS
	 FROM [dbo].[Inventory] 
	WHERE inventory_id IN 
							(SELECT inventory_id
							FROM [dbo].[return_to_wholesaler_items] 
							WHERE returntowholesaler_Id IN 
							(SELECT returntowholesaler_Id 
							FROM [dbo].[ReturnToWholesaler]  
							WHERE pharmacy_id = @pharmaId)) -- @pharmaId

	--COUNT
	SELECT @count =ISNULL(count(*),0) from #TEMP_RET_HIS

	
    -- SELECT INVENTORY ID FOR INSERTED PHARMACY ID
	SELECT 
		inventory_id	AS InventoryId,
		pharmacy_id		AS PharmacyId,
		wholesaler_id	AS WholesalerId,
		drug_name		AS DrugName,
		ndc				AS NDC,
		pack_size		AS Quantity,
		price			AS Price,	
		@count			AS Count,
		strength        AS Strength
	FROM #TEMP_RET_HIS
	WHERE (drug_name LIKE '%'+ISNULL(@search,drug_name)+'%' OR 
	ndc LIKE '%'+ISNULL(@search,ndc)+'%')
	ORDER BY inventory_id desc
	OFFSET  @pSize * (@pNumber - 1)   ROWS
    FETCH NEXT @pSize ROWS ONLY	

	DROP TABLE #TEMP_RET_HIS
END

--exec usp_itemsReturnHistory 1,10,1,'40mg'


--select * from return_to_wholesaler_items

GO
/****** Object:  StoredProcedure [dbo].[usp_most_least_quantity]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

--exec usp_most_least_quantity 1417,1000,1,''
CREATE PROCEDURE [dbo].[usp_most_least_quantity] 
	@pharmacy_Id INT,
	@pageSize INT,
	@pageNumber INT,
	@searchString NVARCHAR(250) = '' 
AS
BEGIN

	SET NOCOUNT ON;
	
	-- DECLARING VARIABLES
	DECLARE @pharma_Id INT = @pharmacy_Id
	DECLARE @pSize INT = @pageSize
	DECLARE @pNumber INT = @pageNumber
	DECLARE @search NVARCHAR(250) = @searchString 
	DECLARE @expMonth TINYINT = 0
	DECLARE @minValue MONEY = 250.00
	DECLARE @count INT 

	-- GET MEDICINE EXPIRY AND SET ON VARIABLE 
	SET @expMonth = (SELECT expiry_month 
					FROM [dbo].[Inv_Exp_Config] 
					WHERE ISNULL(is_deleted,0) = 0)

	-- GET AND SET RECORD IN INVENTORY TABLE TO TEMP TABLE #MOST_LEAST_QTY

	-- NOTE : currently in inventory table price stored is total price and quantity is total quantity 
	-- FORMULA : $ value on hand for a particular NDC = totals quantity per unit x total cost per unit
	SELECT * INTO #MOST_LEAST_QTY 
		FROM [dbo].[inventory]
		WHERE price >= @minValue 
		AND pharmacy_id = @pharma_Id
		AND (ISNULL(is_deleted,0) = 0)  
		AND	(ISNULL(pack_size,0) > 0) 		
		AND (drug_name LIKE '%'+ISNULL(@search,drug_name)+'%' OR   
			  ndc LIKE '%'+ISNULL(@search,ndc)+'%')

	-- GET & SET COUNT
	SELECT @count = ISNULL(COUNT(*),0) FROM #MOST_LEAST_QTY

	-- SELECT RECORD FROM TEMP TABLE AND PUT SEARCHING AND PAGINATION 
	-- NOTE : RECORD IS ORDERED BY 'PRICE' FROM HIGH TO LOW
	
	

	 IF @PageSize > 0
	 BEGIN
		SELECT 
			inventory_id	AS InventoryId,
			pharmacy_id		AS PharmacyId,
			wholesaler_id	AS WholesalerId,
			drug_name		AS DrugName,
			ndc				AS NDC,
			pack_size		AS Quantity,
			price			AS Price,
			created_on      AS CreatedOn,
			(pack_size * price)	  AS ExtendedQuantity,
			EOMONTH(DATEADD(mm,+@expMonth,created_on)) AS ExpiryDate,
			@count			AS Count,
			strength       AS Strength
	FROM #MOST_LEAST_QTY
	ORDER BY price DESC
	OFFSET  @pSize * (@pNumber - 1) ROWS
	FETCH NEXT @pSize ROWS ONLY
	END
	ELSE
	BEGIN
	SELECT 
			inventory_id	AS InventoryId,
			pharmacy_id		AS PharmacyId,
			wholesaler_id	AS WholesalerId,
			drug_name		AS DrugName,
			ndc				AS NDC,
			pack_size		AS Quantity,
			price			AS Price,
			created_on      AS CreatedOn,
			(pack_size * price)	  AS ExtendedQuantity,
			EOMONTH(DATEADD(mm,+@expMonth,created_on)) AS ExpiryDate,
			@count			AS Count,
				strength       AS Strength
	FROM #MOST_LEAST_QTY
	ORDER BY price DESC
	
	END	 

	-- DROP TEMP TABLE
	DROP TABLE #MOST_LEAST_QTY
END



GO
/****** Object:  StoredProcedure [dbo].[usp_ndcpacksizeupdate]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:		<Author,Ankit Joshi>
-- Create date: <Create Date, 06-25-2018>
-- Description:	<Description,stored procedure to update pack size, strength in inventory table using edi_inventory table>
-- =============================================
CREATE PROCEDURE [dbo].[usp_ndcpacksizeupdate]	
AS
BEGIN
	
	SET NOCOUNT ON;

	BEGIN TRY
		
		INSERT INTO LOG(Application, Logged, Level, Message) 
		VALUES('usp_ndcpacksizeupdate', GETDATE(),'inventory data update started','stored procedure to update pack size, strength in inventory table using edi_inventory table.'); 

		UPDATE INV 
			SET INV.[NDC_Packsize] = (CAST(ISNULL(edi_inv.[PO4_Pack_FDBSize],0.0) AS Decimal(10,2)) * CAST(ISNULL(edi_inv.[PO4_Pack_MetricSize],0.0) AS DECIMAL(10,2)))
		FROM [dbo].[inventory] INV
		INNER JOIN [dbo].[edi_inventory] edi_inv
		ON ISNULL(INV.ndc,0) = ISNULL(TRY_PARSE(edi_inv.LIN_NDC AS BIGINT),0) 
		
	END TRY
	BEGIN CATCH 

		--,ERROR_NUMBER() AS ErrorNumber
		INSERT INTO LOG(Application, Logged, Level, Message)
		SELECT 'usp_ndcpacksizeupdate' AS Application,
				GetDate() AS Logged,
				ERROR_LINE() AS ErrorLine,
				ERROR_MESSAGE() AS ErrorMessage;
				  
	END CATCH	
END



GO
/****** Object:  StoredProcedure [dbo].[usp_pendingOrderDetail]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO




-- ================================================================================
-- Author:		<Author,  Ankit Joshi>
-- Create date: <Create Date, 2018-05-21>
-- Description:	<Description, user defined procedure to get pending orders.>
--exec [dbo].[usp_pendingOrderDetail]  936853194,10,1,''
-- ================================================================================

CREATE PROCEDURE [dbo].[usp_pendingOrderDetail] 
	-- Add the parameters for the stored procedure here
	@invNumber nvarchar(50),
	@page_size INT,
	@page_number INT,
	@search_string NVARCHAR(250) = ''
AS
BEGIN
	-- DECLARE VARIABLES
	DECLARE @InvoiceNumber nvarchar(50) = @invNumber
	DECLARE @pSize INT = @page_size
	DECLARE @pNumber INT = @page_number
	DECLARE @search NVARCHAR(250) = @search_string
	DECLARE @count INT

	-- SET NOCOUNT ON 
	SET NOCOUNT ON;

	-- JOIN ON INVOICE, INVOICE_LINE_ITEMS, INVOICE_ADDITIONAL_ITEMS 
	SELECT 
		inv.[invoice_number],inv.[invoice_date],inv.[purchase_order_number],inv.pharmacy_id,
		itm.[invoiced_quantity],itm.seller_number,itm.ndc_upc,itm.unit_price,
		remaining.[remaining_quantity],
		ack.[StatusCode],
		ack.[QTY],
		ack.ProductId,
		PID.product_desc
		INTO #ORDER_DETAILS
	FROM  invoice as inv
	inner join [dbo].[invoice_line_items] itm 
	on inv.[invoice_id] = itm.invoice_id
	inner join [dbo].[invoice_additionalItem] remaining
	on itm.[invoice_lineitem_id] = remaining.[invoice_items_id]
	INNER JOIN [dbo].[invoice_productDescription] AS PID
	ON PID.invoice_items_id = itm.invoice_lineitem_id
	inner join [dbo].[Ack_BAK_PurchaseOrder] bak
	on inv.[purchase_order_number] = bak.[PurchaseOrderNumber]
	inner join [dbo].[Ack_LineItem] lineitem
	on bak.BAK_ID = lineitem.[BAK_ID]
	inner join [dbo].[Ack_LineItemACK] ack
	on lineitem.[LineItem_ID] = ack.[LineItem_ID]
	where inv.invoice_number = @InvoiceNumber
	AND (ISNULL(inv.is_deleted,0) = 0)  
	AND ack.[StatusCode] in ('IB','IR','IW','IQ')
	AND (PID.product_desc LIKE '%'+ISNULL(@search,PID.product_desc)+'%' OR   
	itm.ndc_upc LIKE '%'+ISNULL(@search,itm.ndc_upc)+'%')

	-- COUNT THE NUMBER OF RECORDS IN TEMP TABLE
	SELECT @count = ISNULL(COUNT(*),0) FROM #ORDER_DETAILS

	-- SELECT RECORD FROM TEMPORARY TABLE
	SELECT 
		invoice_number			 AS Invoice_Number,
		invoice_date			 AS Invoice_Date,
		[purchase_order_number]  AS PurchaseOrderNumber,
		ndc_upc					 AS DrugIndentifier,
		invoiced_quantity		 AS Invoiced,
		remaining_quantity		 AS RemainingQty,
		unit_price				 AS UnitPrice,
		product_desc			 AS Product,
		pharmacy_id				 AS PharmacyId,
		[StatusCode]			 AS ACKStatus,
		[QTY]					 AS QuantityReceived,
		@count					 AS Count
	FROM #ORDER_DETAILS
	ORDER BY invoice_date DESC
	OFFSET  @pSize * (@pNumber - 1) ROWS
	FETCH NEXT @pSize ROWS ONLY

	-- DROP TEMPORARY TABLE
	DROP TABLE #ORDER_DETAILS
END





GO
/****** Object:  StoredProcedure [dbo].[usp_pendingOrderDetail_backup20180625]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO




-- ================================================================================
-- Author:		<Author,  Ankit Joshi>
-- Create date: <Create Date, 2018-05-21>
-- Description:	<Description, user defined procedure to get pending orders.>
--exec [dbo].[usp_pendingOrderDetail]  936853194,10,1,''
-- ================================================================================

CREATE PROCEDURE [dbo].[usp_pendingOrderDetail_backup20180625] 
	-- Add the parameters for the stored procedure here
	@invNumber nvarchar(50),
	@page_size INT,
	@page_number INT,
	@search_string NVARCHAR(250) = ''
AS
BEGIN
	-- DECLARE VARIABLES
	DECLARE @InvoiceNumber nvarchar(50) = @invNumber
	DECLARE @pSize INT = @page_size
	DECLARE @pNumber INT = @page_number
	DECLARE @search NVARCHAR(250) = @search_string
	DECLARE @count INT

	-- SET NOCOUNT ON 
	SET NOCOUNT ON;

	-- JOIN ON INVOICE, INVOICE_LINE_ITEMS, INVOICE_ADDITIONAL_ITEMS 
	SELECT 
		INV.invoice_number,
		INV.invoice_date,
		IT1.ndc_upc,
		IT1.invoiced_quantity,
		IT1.product_qual, 
		ITM.remaining_quantity,
		IT1.unit_price,
		ITM.item_order_status,
		INV.pharmacy_id,
		PID.product_desc
		INTO #ORDER_DETAILS
	FROM [dbo].[invoice] AS INV
	INNER JOIN 
	[dbo].[invoice_line_items] AS IT1
	ON INV.invoice_id = IT1.invoice_id
	INNER JOIN [dbo].[invoice_productDescription] AS PID
	ON PID.invoice_items_id = IT1.invoice_lineitem_id
	INNER JOIN [dbo].[invoice_additionalItem] AS ITM
	ON ITM.invoice_items_id = IT1.invoice_lineitem_id
	WHERE INV.invoice_number = @InvoiceNumber
	AND (ISNULL(INV.is_deleted,0) = 0)  
	AND (PID.product_desc LIKE '%'+ISNULL(@search,PID.product_desc)+'%' OR   
	IT1.ndc_upc LIKE '%'+ISNULL(@search,IT1.ndc_upc)+'%')

	-- COUNT THE NUMBER OF RECORDS IN TEMP TABLE
	SELECT @count = ISNULL(COUNT(*),0) FROM #ORDER_DETAILS

	-- SELECT RECORD FROM TEMPORARY TABLE
	SELECT 
		invoice_number			 AS Invoice_Number,
		invoice_date			 AS Invoice_Date,
		product_qual			 AS IdentifierType,
		ndc_upc					 AS DrugIndentifier,
		invoiced_quantity		 AS Invoiced,
		remaining_quantity		 AS RemainingQty,
		unit_price				 AS UnitPrice,
		item_order_status		 AS OrderStatus,
		product_desc			 AS Product,
		pharmacy_id				 AS PharmacyId,
		@count					 AS Count
	FROM #ORDER_DETAILS
	ORDER BY invoice_date DESC
	OFFSET  @pSize * (@pNumber - 1) ROWS
	FETCH NEXT @pSize ROWS ONLY

	-- DROP TEMPORARY TABLE
	DROP TABLE #ORDER_DETAILS
END





GO
/****** Object:  StoredProcedure [dbo].[usp_pendingOrders]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO



-- ================================================================================
-- Author:		<Author,  Ankit Joshi>
-- Create date: <Create Date, 2018-05-21>
-- Description:	<Description, user defined procedure to get pending orders.>
--exec usp_pendingOrders  1417,100,1,''
-- ================================================================================

CREATE PROCEDURE [dbo].[usp_pendingOrders] 
	-- Add the parameters for the stored procedure here
	@pharmacy_id INT,
	@page_size INT,
	@page_number INT,
	@search_string NVARCHAR(250) = ''
AS
BEGIN
	-- DECLARE VARIABLES
	DECLARE @pharma_Id INT = @pharmacy_id
	DECLARE @pSize INT = @page_size
	DECLARE @pNumber INT = @page_number
	DECLARE @search NVARCHAR(250) = @search_string
	DECLARE @count INT

	-- SET NOCOUNT ON 
	SET NOCOUNT ON;

	-- JOIN ON INVOICE, INVOICE_LINE_ITEMS, INVOICE_ADDITIONAL_ITEMS 
	SELECT 
		INV.invoice_number,
		INV.invoice_date,
		IT1.ndc_upc,
		IT1.invoiced_quantity, 
		ITM.remaining_quantity,
		IT1.unit_price,
		ITM.item_order_status,
		INV.pharmacy_id
	INTO #PENDING_ORDER
	FROM [dbo].[invoice_additionalItem] AS ITM
	INNER JOIN 
	[dbo].[invoice_line_items] AS IT1
	ON ITM.invoice_items_id = IT1.invoice_lineitem_id
	INNER JOIN 
	[dbo].[invoice] AS INV
	ON IT1.invoice_id = INV.invoice_id
	WHERE pharmacy_id = @pharma_Id
	AND (ISNULL(INV.is_deleted,0) = 0)  
	AND (INV.invoice_number LIKE '%'+ISNULL(@search,INV.invoice_number)+'%' OR   
	CAST(INV.invoice_date AS DATE) LIKE '%'+ISNULL(@search,INV.invoice_date)+'%')

	-- COUNT THE NUMBER OF RECORDS IN TEMP TABLE
	SELECT @count = ISNULL(COUNT(*),0) FROM #PENDING_ORDER

	-- SELECT RECORD FROM TEMPORARY TABLE
	SELECT 
		invoice_number			 AS Invoice_Number,
		invoice_date			 AS Invoice_Date,
		ndc_upc					 AS NDC,
		invoiced_quantity		 AS Invoiced,
		remaining_quantity		 AS RemainingQty,
		unit_price				 AS UnitPrice,
		item_order_status		 AS OrderStatus,
		pharmacy_id				 AS PharmacyId,
		@count					 AS Count
	FROM #PENDING_ORDER
	ORDER BY invoice_date DESC
	OFFSET  @pSize * (@pNumber - 1) ROWS
	FETCH NEXT @pSize ROWS ONLY

	-- DROP TEMPORARY TABLE
	DROP TABLE #PENDING_ORDER
END




GO
/****** Object:  StoredProcedure [dbo].[usp_pos_sync]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ========================================================================================================================================
-- Author:		<Author,Ankit Joshi>
-- Create date: <Create Date, 08-05-2018>
-- Description:	<Description, sp to get pos sync details. This will get the details of all the edi files that gets failed on parsing>
-- ========================================================================================================================================
CREATE PROCEDURE [dbo].[usp_pos_sync]
	-- Add the parameters for the stored procedure here
	@pharmacy_id INT,
	@pagesize INT,
	@pagenumber INT,
	@searchstring nvarchar(250) = ''
AS
BEGIN

	-- DECLARING VARIABLES 
	DECLARE @pharma_id INT = @pharmacy_id
	DECLARE @pSize INT = @pagesize
	DECLARE @pNumber INT = @pagenumber
	DECLARE @search nvarchar(250) = @searchstring
	DECLARE @count INT

	-- SET NOCOUNT ON added to prevent extra result sets from
	SET NOCOUNT ON;
	--SELECT * FROM [dbo].[rx30_batch_details]
	-- SELECT ALL FROM EDI BATCH DETAILS WHERE BATCH ID IN EDI MASTER
	SELECT * INTO #RX30_PARSER_STATUS FROM [dbo].[rx30_batch_details]
	WHERE rx30_batch_id in (SELECT rx30_batch_id FROM [dbo].[rx30_batch_master]
							WHERE pharmacy_id = @pharma_id AND is_deleted = 0)
	AND is_error = 1
	AND [filename] LIKE '%'+ISNULL(@search,[filename])+'%'
	ORDER BY rx30_batch_details_id DESC
	OFFSET  @pSize * (@pNumber - 1) ROWS
    FETCH NEXT @pSize ROWS ONLY
	
	-- GET RECORD COUNT
	 SELECT @count = (ISNULL(COUNT(*),0)) FROM #RX30_PARSER_STATUS
	
	-- SELECT RECORD 
	SELECT 
	[filename] AS File_Name,
	[is_success] AS Success,
	[is_error] AS Error,
	@count AS Count 
	FROM #RX30_PARSER_STATUS

	DROP TABLE #RX30_PARSER_STATUS
END





GO
/****** Object:  StoredProcedure [dbo].[usp_purchaseSummary]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:		<Author,Ankit Joshi>
-- Create date: <Create Date, 2018-05-11>
-- Description:	<Description, stored procedure to get purchase summary>
-- EXEC usp_purchaseSummary 1417
-- =============================================
CREATE PROCEDURE [dbo].[usp_purchaseSummary]
	@pharmacyId INT

AS
BEGIN
	
	-- DECLARE VARIABLES
	DECLARE @pharmaId INT = @pharmacyId
	DECLARE @START_DATE DATETIME
	DECLARE @END_DATE DATETIME
	Declare @index int=1,@count int=7; 
	SET NOCOUNT ON;

	-- GET START & END DATE OF WEEK
	SET  @START_DATE = DATEADD(DAY, 1-DATEPART(dw, GETDATE()), CONVERT(date,GETDATE())) 
	SET @END_DATE = DATEADD(DAY, 7-DATEPART(dw, GETDATE()), CONVERT(date,GETDATE()))
	
	-- GET RECORD FOR CREATING PURCHASE SUMMARY GRAPH AT PHARMACY DASHBOARD
	CREATE TABLE #Temp_purchaseSummary(
	InvoiceDate  DATETIME,
	DaysName     NVARCHAR(300),
	TotalUnits   DECIMAL
	)

	INSERT INTO #Temp_purchaseSummary
	SELECT
	 INV.INVOICE_DATE  AS InvoiceDate,DATENAME(dw,INV.INVOICE_DATE) as DaysName,
	--INV.INVOICE_ID, INV.INVOICE_NUMBER
	SUM(ITM.UNIT_PRICE) AS TotalUnits
	--SUM(ITM.INVOICED_QUANTITY)
	FROM [dbo].[INVOICE] AS INV
	INNER JOIN [dbo].[invoice_line_items] AS ITM
	ON INV.INVOICE_ID = ITM.INVOICE_ID
	WHERE INV.IS_DELETED = 0
	AND INV.PHARMACY_ID = @pharmaId 
	AND INV.INVOICE_DATE BETWEEN @START_DATE AND @END_DATE
	GROUP BY INV.INVOICE_DATE

	--SELECT * FROM #Temp_purchaseSummary

--==========================================================
--purchase summary form CSV import

		--DECLARE @START_DATE DATETIME
		--DECLARE @END_DATE DATETIME
		--SET  @START_DATE = DATEADD(DAY, 1-DATEPART(dw, GETDATE()), CONVERT(date,GETDATE())) 
		--SET @END_DATE = DATEADD(DAY, 7-DATEPART(dw, GETDATE()), CONVERT(date,GETDATE()))
	
	Select wCSV.pack_size/ COALESCE(
        CASE 
             WHEN inv.NDC_Packsize = 0 THEN 1
             ELSE ISNULL(inv.NDC_Packsize,1)
        END, 1)
	 AS TotalUnitsCsv, 
			 CONVERT (date, wCSV.purchasedate)  AS PurchaseDate,
			DATENAME(dw,wCSV.purchasedate) as DaysName
		 INTO #Temp_purchaseSummaryCSV
			FROM wholesaler_CSV_Import wCSV
			INNER JOIN wholesaler_csvimport_batch_details wCSVBD ON wCSV.csvbatch_id = wCSVBD.csvimport_batch_details_id
			INNER JOIN wholesaler_csvimport_batch_master wCSVBM  ON wCSVBD.csvimport_batch_id = wCSVBM.csvimport_batch_id
			INNER JOIN inventory inv ON wCSV.ndc = inv.ndc
			WHERE wCSVBM.pharmacy_id = @pharmaId 
			--AND wCSV.purchasedate BETWEEN @START_DATE AND @END_DATE
			
		SELECT round(SUM(TotalUnitsCsv),2) AS TotalUnitsCsv,
			   	PurchaseDate,
				DATENAME(dw,purchasedate) as DaysName
	    INTO #Temp_purchaseSummaryCSV2
		FROM #Temp_purchaseSummaryCSV
		WHERE purchasedate BETWEEN @START_DATE AND @END_DATE
		GROUP BY purchasedate

		--select * from #Temp_purchaseSummaryCSV2

		--DROP table #Temp_purchaseSummaryCSV
		--DROP table #Temp_purchaseSummaryCSV2





--==============================================================


	;With CTE as (
	
	SELECT FORMAT(@START_DATE,'dddd') 'Day Name',@START_DATE 'Date'
	UNION 
	SELECT FORMAT(DateAdd(day, 1,@START_DATE),'dddd') 'Day Name',DateAdd(day, 1,@START_DATE)'Date'
	UNION 
	SELECT FORMAT(DateAdd(day, 2,@START_DATE),'dddd') 'Day Name',DateAdd(day, 2,@START_DATE)'Date'
	UNION 
	SELECT FORMAT(DateAdd(day, 3,@START_DATE),'dddd') 'Day Name',DateAdd(day, 3,@START_DATE)'Date'
	UNION 
	SELECT FORMAT(DateAdd(day, 4,@START_DATE),'dddd') 'Day Name',DateAdd(day,4,@START_DATE)'Date'
	UNION 
	SELECT FORMAT(DateAdd(day, 5,@START_DATE),'dddd') 'Day Name',DateAdd(day, 5,@START_DATE)'Date'
	UNION 
	SELECT FORMAT(DateAdd(day, 6,@START_DATE),'dddd') 'Day Name',DateAdd(day, 6,@START_DATE)'Date'
	--union 
	--SELECT FORMAT(DateAdd(day, 7,GETDATE()),'dddd') 'Day Name',DateAdd(day, 7,GETDATE())'Date'
) 
	select IsNull(temp.InvoiceDate,cte.date) as InvoiceDate,IsNull(temp.DaysName,cte.[Day Name]) as DaysName,
	(ISnull(temp.TotalUnits,0) +IsNull(tpsCSV2.TotalUnitsCsv,0)) as TotalUnits  from CTE cte
     left join #Temp_purchaseSummary temp on cte.[Day Name]=temp.DaysName
	 left Join #Temp_purchaseSummaryCSV2 tpsCSV2 ON cte.[Day Name]=tpsCSV2.DaysName
	 order by cte.Date




END




GO
/****** Object:  StoredProcedure [dbo].[usp_purchaseSummary_backup]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:		<Author,Ankit Joshi>
-- Create date: <Create Date, 2018-05-11>
-- Description:	<Description, stored procedure to get purchase summary>
-- EXEC usp_purchaseSummary_backup 1417
-- =============================================
CREATE PROCEDURE [dbo].[usp_purchaseSummary_backup]
	@pharmacyId INT

AS
BEGIN
	
	-- DECLARE VARIABLES
	DECLARE @pharmaId INT = @pharmacyId
	DECLARE @START_DATE DATETIME
	DECLARE @END_DATE DATETIME
	Declare @index int=1,@count int=7; 
	SET NOCOUNT ON;

	-- GET START & END DATE OF WEEK
	SET  @START_DATE = DATEADD(DAY, 1-DATEPART(dw, GETDATE()), CONVERT(date,GETDATE())) 
	SET @END_DATE = DATEADD(DAY, 7-DATEPART(dw, GETDATE()), CONVERT(date,GETDATE()))
	
	-- GET RECORD FOR CREATING PURCHASE SUMMARY GRAPH AT PHARMACY DASHBOARD
	CREATE TABLE #Temp_purchaseSummary(
	InvoiceDate  DATETIME,
	DaysName     NVARCHAR(300),
	TotalUnits   DECIMAL
	)

	INSERT INTO #Temp_purchaseSummary
	SELECT
	 INV.INVOICE_DATE  AS InvoiceDate,DATENAME(dw,INV.INVOICE_DATE) as DaysName,
	--INV.INVOICE_ID, INV.INVOICE_NUMBER
	SUM(ITM.UNIT_PRICE) AS TotalUnits
	--SUM(ITM.INVOICED_QUANTITY)
	FROM [dbo].[INVOICE] AS INV
	INNER JOIN [dbo].[invoice_line_items] AS ITM
	ON INV.INVOICE_ID = ITM.INVOICE_ID
	WHERE INV.IS_DELETED = 0
	AND INV.PHARMACY_ID = @pharmaId 
	AND INV.INVOICE_DATE BETWEEN @START_DATE AND @END_DATE
	GROUP BY INV.INVOICE_DATE

	--SELECT * FROM #Temp_purchaseSummary

--==========================================================
--purchase summary form CSV import

		--DECLARE @START_DATE DATETIME
		--DECLARE @END_DATE DATETIME
		--SET  @START_DATE = DATEADD(DAY, 1-DATEPART(dw, GETDATE()), CONVERT(date,GETDATE())) 
		--SET @END_DATE = DATEADD(DAY, 7-DATEPART(dw, GETDATE()), CONVERT(date,GETDATE()))
	
	Select wCSV.pack_size/ COALESCE(
        CASE 
             WHEN inv.NDC_Packsize = 0 THEN 1
             ELSE ISNULL(inv.NDC_Packsize,1)
        END, 1)
	 AS TotalUnitsCsv, 
			 CONVERT (date, wCSV.purchasedate)  AS PurchaseDate,
			DATENAME(dw,wCSV.purchasedate) as DaysName
		 INTO #Temp_purchaseSummaryCSV
			FROM wholesaler_CSV_Import wCSV
			INNER JOIN wholesaler_csvimport_batch_details wCSVBD ON wCSV.csvbatch_id = wCSVBD.csvimport_batch_details_id
			INNER JOIN wholesaler_csvimport_batch_master wCSVBM  ON wCSVBD.csvimport_batch_id = wCSVBM.csvimport_batch_id
			INNER JOIN inventory inv ON wCSV.ndc = inv.ndc
			WHERE wCSVBM.pharmacy_id = @pharmaId 
			--AND wCSV.purchasedate BETWEEN @START_DATE AND @END_DATE
			
		SELECT round(SUM(TotalUnitsCsv),2) AS TotalUnitsCsv,
			   	PurchaseDate,
				DATENAME(dw,purchasedate) as DaysName
	    INTO #Temp_purchaseSummaryCSV2
		FROM #Temp_purchaseSummaryCSV
		WHERE purchasedate BETWEEN @START_DATE AND @END_DATE
		GROUP BY purchasedate

		--select * from #Temp_purchaseSummaryCSV2

		--DROP table #Temp_purchaseSummaryCSV
		--DROP table #Temp_purchaseSummaryCSV2





--==============================================================


	;With CTE as (
	
	SELECT FORMAT(@START_DATE,'dddd') 'Day Name',@START_DATE 'Date'
	UNION 
	SELECT FORMAT(DateAdd(day, 1,@START_DATE),'dddd') 'Day Name',DateAdd(day, 1,@START_DATE)'Date'
	UNION 
	SELECT FORMAT(DateAdd(day, 2,@START_DATE),'dddd') 'Day Name',DateAdd(day, 2,@START_DATE)'Date'
	UNION 
	SELECT FORMAT(DateAdd(day, 3,@START_DATE),'dddd') 'Day Name',DateAdd(day, 3,@START_DATE)'Date'
	UNION 
	SELECT FORMAT(DateAdd(day, 4,@START_DATE),'dddd') 'Day Name',DateAdd(day,4,@START_DATE)'Date'
	UNION 
	SELECT FORMAT(DateAdd(day, 5,@START_DATE),'dddd') 'Day Name',DateAdd(day, 5,@START_DATE)'Date'
	UNION 
	SELECT FORMAT(DateAdd(day, 6,@START_DATE),'dddd') 'Day Name',DateAdd(day, 6,@START_DATE)'Date'
	--union 
	--SELECT FORMAT(DateAdd(day, 7,GETDATE()),'dddd') 'Day Name',DateAdd(day, 7,GETDATE())'Date'
) 
	select IsNull(temp.InvoiceDate,cte.date)[Date],IsNull(temp.DaysName,cte.[Day Name])DaysName,
	(ISnull(temp.TotalUnits,0) +IsNull(tpsCSV2.TotalUnitsCsv,0)) from CTE cte
     left join #Temp_purchaseSummary temp on cte.[Day Name]=temp.DaysName
	 left Join #Temp_purchaseSummaryCSV2 tpsCSV2 ON cte.[Day Name]=tpsCSV2.DaysName
	 order by cte.Date




END




GO
/****** Object:  StoredProcedure [dbo].[usp_purchaseSummary_backup_25_07_2018]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:		<Author,Ankit Joshi>
-- Create date: <Create Date, 2018-05-11>
-- Description:	<Description, stored procedure to get purchase summary>
-- EXEC usp_purchaseSummary 1417
-- =============================================
Create PROCEDURE [dbo].[usp_purchaseSummary_backup_25_07_2018]
	@pharmacyId INT

AS
BEGIN
	
	-- DECLARE VARIABLES
	DECLARE @pharmaId INT = @pharmacyId
	DECLARE @START_DATE DATETIME
	DECLARE @END_DATE DATETIME
	Declare @index int=1,@count int=7; 
	SET NOCOUNT ON;

	-- GET START & END DATE OF WEEK
	SET  @START_DATE = DATEADD(DAY, 1-DATEPART(dw, GETDATE()), CONVERT(date,GETDATE())) 
	SET @END_DATE = DATEADD(DAY, 7-DATEPART(dw, GETDATE()), CONVERT(date,GETDATE()))
	
	-- GET RECORD FOR CREATING PURCHASE SUMMARY GRAPH AT PHARMACY DASHBOARD
	CREATE TABLE #Temp_purchaseSummary(
	InvoiceDate  DATETIME,
	DaysName     NVARCHAR(300),
	TotalUnits   DECIMAL
	)

	INSERT INTO #Temp_purchaseSummary
	SELECT
	 INV.INVOICE_DATE  AS InvoiceDate,DATENAME(dw,INV.INVOICE_DATE) as DaysName,
	--INV.INVOICE_ID, INV.INVOICE_NUMBER
	SUM(ITM.UNIT_PRICE) AS TotalUnits
	--SUM(ITM.INVOICED_QUANTITY)
	FROM [dbo].[INVOICE] AS INV
	INNER JOIN [dbo].[invoice_line_items] AS ITM
	ON INV.INVOICE_ID = ITM.INVOICE_ID
	WHERE INV.IS_DELETED = 0
	AND INV.PHARMACY_ID = @pharmaId 
	AND INV.INVOICE_DATE BETWEEN @START_DATE AND @END_DATE
	GROUP BY INV.INVOICE_DATE

	--SELECT * FROM #Temp_purchaseSummary




	;With CTE as (
	
	SELECT FORMAT(@START_DATE,'dddd') 'Day Name',@START_DATE 'Date'
	UNION 
	SELECT FORMAT(DateAdd(day, 1,@START_DATE),'dddd') 'Day Name',DateAdd(day, 1,@START_DATE)'Date'
	UNION 
	SELECT FORMAT(DateAdd(day, 2,@START_DATE),'dddd') 'Day Name',DateAdd(day, 2,@START_DATE)'Date'
	UNION 
	SELECT FORMAT(DateAdd(day, 3,@START_DATE),'dddd') 'Day Name',DateAdd(day, 3,@START_DATE)'Date'
	UNION 
	SELECT FORMAT(DateAdd(day, 4,@START_DATE),'dddd') 'Day Name',DateAdd(day,4,@START_DATE)'Date'
	UNION 
	SELECT FORMAT(DateAdd(day, 5,@START_DATE),'dddd') 'Day Name',DateAdd(day, 5,@START_DATE)'Date'
	UNION 
	SELECT FORMAT(DateAdd(day, 6,@START_DATE),'dddd') 'Day Name',DateAdd(day, 6,@START_DATE)'Date'
	--union 
	--SELECT FORMAT(DateAdd(day, 7,GETDATE()),'dddd') 'Day Name',DateAdd(day, 7,GETDATE())'Date'
) 


	select IsNull(temp.InvoiceDate,cte.date)[Date],IsNull(temp.DaysName,cte.[Day Name])DaysName,temp.TotalUnits from CTE cte
     left join #Temp_purchaseSummary temp on cte.[Day Name]=temp.DaysName
	 order by cte.Date



END




GO
/****** Object:  StoredProcedure [dbo].[usp_sales_summary]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================
-- Author:		<Author,,Ankit Joshi>
-- Create date: <Create Date,,2018-06-01>
-- Description:	<Description,, user defined procedure to get the purchase summary monthly basis>
-- EXEC usp_sales_summary
-- =============================================
CREATE PROCEDURE [dbo].[usp_sales_summary]
	-- Add the parameters for the stored procedure here
AS
BEGIN
	-- SET NOCOUNT ON 
	SET NOCOUNT ON;
	Declare @startyear datetime

	set @startyear = DATEADD(yy, DATEDIFF(yy, 0, GETDATE()), 0)

	SELECT 
	DATEPART(month,created_on) [Month], 
	SUM(amount) [amount]
	INTO #SALES_SUMMARY
	FROM [dbo].[payments]
	--WHERE CREATED_ON BETWEEN  @startyear AND GETDATE()
	GROUP BY DATEPART(month, created_on) 

	
	
		-- TABLE FOR MONTH AND MONTH NAME
		SELECT LEFT(DATENAME(MONTH, DATEADD(MM, s.number, CONVERT(DATETIME, 0))),3) AS [MonthName], 
		MONTH(DATEADD(MM, s.number, CONVERT(DATETIME, 0))) AS [MonthNumber] 
		INTO #MONTH
		FROM master.dbo.spt_values s 
		WHERE [type] = 'P' AND s.number BETWEEN 0 AND 11
		ORDER BY 2
	
		-- OUTER JOIN
		SELECT ISNULL(S.amount,0) AS Sales,M.[MonthName] FROM #SALES_SUMMARY AS S
		RIGHT JOIN 
		#MONTH AS M
		ON 
		S.[Month] = M.[MonthNumber]
		

		-- DROP TEMP TABLE
		DROP TABLE  #SALES_SUMMARY
		DROP TABLE #MONTH
END


--exec usp_sales_summary
--select sum(Sales),MonthName from #Temp_Record Group by MonthName
--select * from #SALES_SUMMARY
--exec [dbo].[usp_sales_summary] 
--select top 10 * from [dbo].[Ack_BAK_PurchaseOrder] order by 1 desc
--select * from payments




GO
/****** Object:  StoredProcedure [dbo].[usp_upcomingExpired_drugs]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


-- =============================================================================================
-- Author:		<Author, Ankit Joshi>
-- Create date: <Create Date, 2018-04-23>
-- Description:	<stored procedure to get drugs list that are going to expire from inventory>
--usp_upcomingExpired_drugs 11,100,1,''
-- ==============================================================================================
CREATE PROCEDURE [dbo].[usp_upcomingExpired_drugs] 
	@pharmacy_id INT,
	@pageSize INT,
	@pageNumber INT,
	@searchString NVARCHAR(250) = ''
AS
BEGIN
	
	-- DECLARING SCALAR VARIABLES
	DECLARE @pharma_id INT = @pharmacy_id
	DECLARE @pgNumber INT = @pageNumber
	DECLARE @pgSize INT = @pageSize
	DECLARE @search NVARCHAR(250) = @searchString
	DECLARE @expMonth TINYINT = 0
	DECLARE @count INT = 0

	SET NOCOUNT ON;
	
	-- GET MEDICINE EXPIRY AND SET ON VARIABLE 
	SET @expMonth = (SELECT expiry_month FROM [dbo].[Inv_Exp_Config] 
	WHERE is_deleted = 0)
	
    -- SELECT RECORD FROM INVENTORY THAT ARE EXPIRED AND STORE IN TEMP TABLE 
	SELECT * INTO 
	#UPCOMING_EXPIRY_DRUGS
	FROM [dbo].[Inventory]
	WHERE pharmacy_id = @pharma_id AND is_deleted = 0 AND pack_size>0
	AND DATEADD(mm,+@expMonth,created_on) > GETDATE()
	AND DATEDIFF(mm,GETDATE(),DATEADD(mm,+@expMonth,created_on)) <= 3
	
	-- GET AND SET COUNT
	 SELECT @count = ISNULL(COUNT(*),0) FROM #UPCOMING_EXPIRY_DRUGS 
	 WHERE (drug_name LIKE '%'+ISNULL(@search,drug_name)+'%' OR   
	 ndc LIKE '%'+ISNULL(@search,ndc)+'%')

	-- SELECT RECORD FROM TEMP TABLE
	

	 IF @PageSize > 0
	 BEGIN
		SELECT 
			inventory_id	AS InventoryId,
			pharmacy_id		AS PharmacyId,
			wholesaler_id	AS WholesalerId,
			drug_name		AS DrugName,
			ndc				AS NDC,
			pack_size		AS Quantity,
			price			AS Price,
			created_on      AS CreatedOn,
			EOMONTH(DATEADD(mm,+@expMonth,created_on)) AS ExpiryDate,
			@count			AS Count,
				strength		AS Strength
	FROM #UPCOMING_EXPIRY_DRUGS
	WHERE (drug_name LIKE '%'+ISNULL(@search,drug_name)+'%' OR   
	ndc LIKE '%'+ISNULL(@search,ndc)+'%')
	ORDER BY inventory_id
	OFFSET  @pgSize * (@pageNumber - 1)   ROWS
	FETCH NEXT @pgSize ROWS ONLY

	END
	ELSE
	BEGIN
	SELECT 
			inventory_id	AS InventoryId,
			pharmacy_id		AS PharmacyId,
			wholesaler_id	AS WholesalerId,
			drug_name		AS DrugName,
			ndc				AS NDC,
			pack_size		AS Quantity,
			price			AS Price,
			created_on      AS CreatedOn,
			EOMONTH(DATEADD(mm,+@expMonth,created_on)) AS ExpiryDate,
			@count			AS Count,
				strength		AS Strength
	FROM #UPCOMING_EXPIRY_DRUGS
	WHERE (drug_name LIKE '%'+ISNULL(@search,drug_name)+'%' OR   
	ndc LIKE '%'+ISNULL(@search,ndc)+'%')
	ORDER BY inventory_id
		
	END	 
	

	-- DROP TEMP TABLE
	DROP TABLE #UPCOMING_EXPIRY_DRUGS
END




GO
/****** Object:  StoredProcedure [dbo].[usp_updateSupscriptionDetails]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:		<Author,,Name>
-- Create date: <Create Date,,2018-05-30>
-- Description:	<Description,, stored procedure to add & update supscription plan details>
-- =============================================

CREATE PROCEDURE [dbo].[usp_updateSupscriptionDetails]
	-- Add the parameters for the stored procedure here
	@pharmacyId INT,
	@subscriptionId INT,
	@paymentDateTime DateTime

AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

	DECLARE @month INT = 0

    -- Insert statements for procedure here
	 SELECT @month = months from [dbo].[sa_subscription_plan]
		where [subscription_plan_id] = @subscriptionId

	update [dbo].[pharmacy_list]
	set
	[subscription_status] = '1',
	[PlanExpireDT]  = DATEADD(mm,+@month,@paymentDateTime)
	where [pharmacy_id] = @pharmacyId

END


GO
/****** Object:  StoredProcedure [dbo].[usp_view_more_inventory]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO





-- =============================================
-- Author:		<Author, Ankit Joshi>
-- Create date: <Create Date, 2018-05-12>
-- Description:	<Description, View more inventories>
--exec usp_view_more_inventory 1417,603499121,2,1,''
-- =============================================
CREATE PROCEDURE [dbo].[usp_view_more_inventory]
	-- Add the parameters for the stored procedure here
	@pharmacyId INT,
	@ndc BIGINT,
	@PageSize		INT,
	@PageNumber    INT,
	@SearchString  nvarchar(250)= ''
AS
BEGIN
	
	-- DECLARE VARIABLES
	DECLARE @pharmaId INT = @pharmacyId
	DECLARE @DrugCode BIGINT = @ndc
	DECLARE @pSize INT = @PageSize
	DECLARE @pNumber INT = @PageNumber
	DECLARE @search  NVARCHAR(250)= @SearchString
	DECLARE @count INT
	DECLARE @expiremonth INT
	
	-- SET NOCOUNT ON 
	SET NOCOUNT ON;

	SELECT @expiremonth=expiry_month FROM Inv_Exp_Config 
	
    -- SELECT RECORD INTO TEMP TABLE
	SELECT	
	     
		 pharmacy_id,				  
		 drug_name,						  
		 ndc,							  
		 pack_size, 				  
		 price,
		 inventory_id,
		 created_on,	
		 batch_id			  
		 INTO #TEMP_VIEWMORE_INVENTORY
		 FROM [dbo].[inventory] 
		 WHERE 	
		 pharmacy_id = @pharmaId
		 AND ndc = @DrugCode
		 AND  is_deleted = 0
		 AND pack_size > 0 
		 AND  (drug_name LIKE '%'+ISNULL(@search,drug_name)+'%' OR (ndc LIKE '%'+ISNULL(@search,ndc)+'%'))
		

		  -- COUNT RECORD
		 SELECT @count= ISNULL(COUNT(*),0) FROM #TEMP_VIEWMORE_INVENTORY 
		
		
		 -- SELECT RECORD FROM TEMP TABLE
		 SELECT
		 inventory_id								AS Id,
		 pharmacy_id								AS PharmacyId,
		 drug_name									AS DrugName,
		 ndc										AS NDC,
		 pack_size									AS PackSize,
		 price										AS Price,
		 @count										As Count,
		 --SUM(pack_size)	OVER(PARTITION BY inventory_id)	AS SUM,
		 batch_id									AS BatchId,
		 EOMONTH(DATEADD(MONTH,@expiremonth,created_on))		AS ExpiryDate
		 INTO #WITHSUM
		 FROM #TEMP_VIEWMORE_INVENTORY
		 ORDER BY price desc
		 OFFSET  @pSize * (@pNumber - 1)   ROWS
         FETCH NEXT @pSize ROWS ONLY	

		 DECLARE @sum_qty decimal(10,2)
		 select @sum_qty = ISNULL(Sum(PackSize),0) FROM #WITHSUM 
		 SELECT *,@sum_qty AS SUM FROM #WITHSUM 

		 -- DROP TABLE #TEMP_VIEWMORE_INVENTORY
		 DROP TABLE #TEMP_VIEWMORE_INVENTORY
		 DROP TABLE #WITHSUM 
END


--select * from inventory
--SELECT * FROM [dbo].[Inv_Exp_Config]





GO
/****** Object:  StoredProcedure [dbo].[usp_wholesaler_sync]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ========================================================================================================================================
-- Author:		<Author,Ankit Joshi>
-- Create date: <Create Date, 08-05-2018>
-- Description:	<Description, sp to get whoesaler pos details. This will get the details of all the edi files that gets failed on parsing>
-- ========================================================================================================================================
CREATE PROCEDURE [dbo].[usp_wholesaler_sync]
	-- Add the parameters for the stored procedure here
	@pharmacy_id INT,
	@pagesize INT,
	@pagenumber INT,
	@searchstring nvarchar(250) = ''
AS
BEGIN

	-- DECLARING VARIABLES 
	DECLARE @pharma_id INT = @pharmacy_id
	DECLARE @pSize INT = @pagesize
	DECLARE @pNumber INT = @pagenumber
	DECLARE @search nvarchar(250) = @searchstring
	DECLARE @count INT

	-- SET NOCOUNT ON added to prevent extra result sets from
	SET NOCOUNT ON;
	
	-- SELECT ALL FROM EDI BATCH DETAILS WHERE BATCH ID IN EDI MASTER
	SELECT * INTO #EDI_PARSER_STATUS FROM [dbo].[edi_batch_details]
	WHERE edi_batch_id in (SELECT edi_batch_id FROM [dbo].[edi_batch_master]
							WHERE pharmacy_id = @pharma_id 
							AND created_by = 810)
	AND status = 'Parser Failed'
	AND [filename] LIKE '%'+ISNULL(@search,[filename])+'%'
	ORDER BY edi_batch_details_id DESC
	OFFSET  @pSize * (@pNumber - 1) ROWS
    FETCH NEXT @pSize ROWS ONLY
	
	-- GET RECORD COUNT
	 SELECT @count = (ISNULL(COUNT(*),0)) FROM #EDI_PARSER_STATUS
	
	-- SELECT RECORD 
	SELECT 
	[filename] AS File_Name,
	filetype AS File_Type,
	[status] AS Status,
	@count AS Count 
	FROM #EDI_PARSER_STATUS

	DROP TABLE #EDI_PARSER_STATUS
END





GO
/****** Object:  StoredProcedure [dbo].[WeeklyInventorySummary]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- exec MonthlyInventorySummary 1417
-- =============================================
-- Create date: <Create Date, 2018-05-29>
-- Description:	<Description, stored procedure to get Inventory summary according to week>
--WeeklyInventorySummary 1417
-- =============================================

CREATE PROC [dbo].[WeeklyInventorySummary]
(
@pharmacyId    INT
)
AS 
BEGIN
--drop table #Temp_MonthlyInventorySummary
	DECLARE @START_DATE DATETIME
	DECLARE @END_DATE DATETIME
	SET NOCOUNT ON;

	-- GET START & END DATE OF WEEK
	SET  @START_DATE = DATEADD(DAY, 1-DATEPART(dw, GETDATE()), CONVERT(date,GETDATE())) 
	SET  @END_DATE = DATEADD(DAY, 7-DATEPART(dw, GETDATE()), CONVERT(date,GETDATE()))
	
	SELECT SUM(price) as Price,CONVERT(DATE,created_on) AS Created_on,
	DATENAME(dw,CONVERT(DATE,created_on)) as DaysName INTO #Temp_MonthlyInventorySummary	FROM inventory
	WHERE ((is_deleted = 0)	AND 
	        (pharmacy_id= @pharmacyId ) AND 
			(created_on BETWEEN @START_DATE AND @END_DATE)
			)
	GROUP BY CONVERT(DATE,created_on)
	--select * from #Temp_MonthlyInventorySummary

	;With CTE as (
	
	SELECT FORMAT(@START_DATE,'dddd') 'Day Name',@START_DATE 'Date'
	UNION 
	SELECT FORMAT(DateAdd(day, 1,@START_DATE),'dddd') 'Day Name',DateAdd(day, 1,@START_DATE)'Date'
	UNION 
	SELECT FORMAT(DateAdd(day, 2,@START_DATE),'dddd') 'Day Name',DateAdd(day, 2,@START_DATE)'Date'
	UNION 
	SELECT FORMAT(DateAdd(day, 3,@START_DATE),'dddd') 'Day Name',DateAdd(day, 3,@START_DATE)'Date'
	UNION 
	SELECT FORMAT(DateAdd(day, 4,@START_DATE),'dddd') 'Day Name',DateAdd(day,4,@START_DATE)'Date'
	UNION 
	SELECT FORMAT(DateAdd(day, 5,@START_DATE),'dddd') 'Day Name',DateAdd(day, 5,@START_DATE)'Date'
	UNION 
	SELECT FORMAT(DateAdd(day, 6,@START_DATE),'dddd') 'Day Name',DateAdd(day, 6,@START_DATE)'Date'

) 
	select LEFT(cte.[Day Name],3) AS WeekMonth,
	 temp.price  AS Price from CTE cte
     left join #Temp_MonthlyInventorySummary temp on cte.[Day Name]=temp.DaysName
	 order by cte.Date

END




GO
/****** Object:  StoredProcedure [dbo].[YearlyInventorySummary]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- exec MonthlyInventorySummary 1417
-- =============================================
-- Create date: <Create Date, 2018-05-29>
-- Description:	<Description, stored procedure to get Inventory summary according to last 5 yr>
--YearlyInventorySummary 1417
-- =============================================

CREATE PROC [dbo].[YearlyInventorySummary]
(
@pharmacyId    INT
)
AS 
BEGIN

	DECLARE @START_DATE INT
	DECLARE @END_DATE INT
	SET NOCOUNT ON;

	/*GET START & END DATE OF WEEK*/

	SET  @START_DATE = YEAR(GETDATE())
	SET  @END_DATE =YEAR(DATEADD(YYYY,-4,GETDATE()))

	/*Get the Price and year from inventory*/

	SELECT  price AS Price,created_on AS Created_on,YEAR(created_on) AS years INTO #Temp_MonthlyInventorySummary1	FROM inventory
	WHERE ((is_deleted = 0)	AND 
	        (pharmacy_id= @pharmacyId ) AND 
			(year(created_on)=@START_DATE AND year(created_on)>@END_DATE)
			)	
			/* Get the last 5 years from CTE*/

			;With CTE as (
	
			SELECT yEAR(GETDATE()) 'year'
			UNION 
			SELECT yEAR(DateAdd(year, -1,GETDATE()))'year'
			UNION 
			SELECT yEAR(DateAdd(year, -2,GETDATE()))'year'
			UNION 
			SELECT yEAR(DateAdd(year, -3,GETDATE()))'year'
			UNION 
			SELECT yEAR(DateAdd(year, -4,GETDATE()))'year'
			) 
		
		SELECT  c.year AS year,IsNull(Aggr1.Price,0) AS Price FROM 
		(
		SELECT
		      IsNull(SUM( temp.Price ),0)  AS Price,
			  years AS Year			  
			  FROM #Temp_MonthlyInventorySummary1 temp  				
			  GROUP BY years
		)
		Aggr1 right outer JOIN CTE c on Aggr1.year = c.year	
	END



GO
/****** Object:  UserDefinedFunction [dbo].[FN_calculate_optimum_qty]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE FUNCTION [dbo].[FN_calculate_optimum_qty](@ndc bigint, @pharmacyId INT)
RETURNS DECIMAL AS
BEGIN
	DECLARE @optimum_qty DECIMAL(10,2)

	/*
	DECLARE @M1 DECIMAL(10,2)
	DECLARE @M2 DECIMAL(10,2)
	DECLARE @M3 DECIMAL(10,2)

	SELECT @M1 =  SUM(qty_disp) FROM [dbo].[RX30_inventory] 
		WHERE MONTH(ISNULL(created_on,GETDATE())) = MONTH(GETDATE())
		AND [ndc] = @ndc AND pharmacy_id = @pharmacyId

	SELECT @M2 =  SUM(qty_disp) FROM [dbo].[RX30_inventory] 
		WHERE MONTH(ISNULL(created_on,GETDATE())) = MONTH(GETDATE()) - 1
		AND [ndc] = @ndc AND pharmacy_id = @pharmacyId

	SELECT @M3 =  SUM(qty_disp) FROM [dbo].[RX30_inventory] 
		WHERE MONTH(ISNULL(created_on,GETDATE())) = MONTH(GETDATE()) - 2
		AND [ndc] = @ndc AND pharmacy_id = @pharmacyId

	SET @optimum_qty = (ISNULL(@M1,0) + ISNULL(@M2,0) + ISNULL(@M3,0))/3
	*/

	DECLARE @cdate DATETIME
	SET @cdate = DATEADD(month, -3, GETDATE())

	/*SELECT @optimum_qty = (sum(qty_disp)/3) */

	--SELECT @optimum_qty = (sum((qty_disp/pack_size))/3) 
	SELECT @optimum_qty = (sum(qty_disp)/3) 
	FROM [dbo].[RX30_inventory] WHERE (
	(ndc=@ndc)
		AND (pharmacy_id =@pharmacyId)
		AND (created_on >=@cdate)
		AND (is_deleted IS NULL)
	)
 

	RETURN  @optimum_qty  
END



--select * from RX30_inventory






GO
/****** Object:  UserDefinedFunction [dbo].[FN_calculate_optimum_qty2]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO


CREATE FUNCTION [dbo].[FN_calculate_optimum_qty2](@ndc bigint, @pharmacyId INT)
RETURNS DECIMAL AS
BEGIN
	DECLARE @optimum_qty DECIMAL(10,2)

	/*
	DECLARE @M1 DECIMAL(10,2)
	DECLARE @M2 DECIMAL(10,2)
	DECLARE @M3 DECIMAL(10,2)

	SELECT @M1 =  SUM(qty_disp) FROM [dbo].[RX30_inventory] 
		WHERE MONTH(ISNULL(created_on,GETDATE())) = MONTH(GETDATE())
		AND [ndc] = @ndc AND pharmacy_id = @pharmacyId

	SELECT @M2 =  SUM(qty_disp) FROM [dbo].[RX30_inventory] 
		WHERE MONTH(ISNULL(created_on,GETDATE())) = MONTH(GETDATE()) - 1
		AND [ndc] = @ndc AND pharmacy_id = @pharmacyId

	SELECT @M3 =  SUM(qty_disp) FROM [dbo].[RX30_inventory] 
		WHERE MONTH(ISNULL(created_on,GETDATE())) = MONTH(GETDATE()) - 2
		AND [ndc] = @ndc AND pharmacy_id = @pharmacyId

	SET @optimum_qty = (ISNULL(@M1,0) + ISNULL(@M2,0) + ISNULL(@M3,0))/3
	*/

	DECLARE @cdate DATETIME
	SET @cdate = DATEADD(month, -3, GETDATE())

	/*SELECT @optimum_qty = (sum(qty_disp)/3) */

	--SELECT @optimum_qty = (sum((qty_disp/pack_size))/3) 
	SELECT @optimum_qty = (sum(qty_disp)/3) 
	FROM [dbo].[RX30_inventory] WHERE (
	(ndc=@ndc)
		AND (pharmacy_id =@pharmacyId)
		AND (created_on >=@cdate)
		AND (is_deleted IS NULL)
	)
 

	RETURN  @optimum_qty  
END



--select * from RX30_inventory






GO
/****** Object:  Table [dbo].[Ack_BAK_PurchaseOrder]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[Ack_BAK_PurchaseOrder](
	[BAK_ID] [int] IDENTITY(1,1) NOT NULL,
	[TX_PurposeCode] [nvarchar](50) NULL,
	[ACK_Type] [nvarchar](50) NULL,
	[PurchaseOrderNumber] [nvarchar](256) NULL,
	[Date] [nvarchar](256) NULL,
	[CTT_TransTotal] [nvarchar](256) NULL,
	[pharmacy_id] [int] NULL,
	[edi_batch_details_id] [int] NULL,
	[WholesellerId] [int] NULL,
	[created_on] [datetime] NULL,
	[deleted_on] [datetime] NULL,
	[isDeleted] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[BAK_ID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[Ack_BuyerPartyDetail]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[Ack_BuyerPartyDetail](
	[BY_ID] [int] IDENTITY(1,1) NOT NULL,
	[EntityIdentifier] [nvarchar](50) NULL,
	[IdCodeQualifier] [nvarchar](50) NULL,
	[IdCode] [nvarchar](256) NULL,
	[BAK_ID] [int] NOT NULL,
PRIMARY KEY CLUSTERED 
(
	[BY_ID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[Ack_LineItem]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[Ack_LineItem](
	[LineItem_ID] [int] IDENTITY(1,1) NOT NULL,
	[AssignedId] [nvarchar](256) NULL,
	[QtyOrdered] [nvarchar](255) NULL,
	[UNIT] [nvarchar](50) NULL,
	[PROD_ID_QUAL] [nvarchar](50) NULL,
	[PROD_ID] [nvarchar](255) NULL,
	[BAK_ID] [int] NOT NULL,
	[pharmacy_id] [int] NULL,
	[edi_batch_details_id] [int] NULL,
PRIMARY KEY CLUSTERED 
(
	[LineItem_ID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[Ack_LineItemACK]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[Ack_LineItemACK](
	[LineItemACK_ID] [int] IDENTITY(1,1) NOT NULL,
	[LineItem_ID] [int] NOT NULL,
	[StatusCode] [nvarchar](50) NULL,
	[QTY] [nvarchar](256) NULL,
	[UNIT] [nvarchar](50) NULL,
	[ProductIdQualifier] [nvarchar](50) NULL,
	[ProductId] [nvarchar](256) NULL,
PRIMARY KEY CLUSTERED 
(
	[LineItemACK_ID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[address_master]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[address_master](
	[address_master_id] [int] IDENTITY(1,1) NOT NULL,
	[pharmacy_user_id] [int] NULL,
	[pharmacy_id] [int] NULL,
	[wholesaler_id] [int] NULL,
	[address_line1] [nvarchar](1000) NULL,
	[address_line2] [nvarchar](1000) NULL,
	[zipcode] [nvarchar](1000) NULL,
	[phone] [nvarchar](1000) NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
	[country_id] [int] NULL,
	[state_id] [int] NULL,
	[city_id] [int] NULL,
	[city] [nvarchar](150) NULL,
PRIMARY KEY CLUSTERED 
(
	[address_master_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[broadcast_message]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[broadcast_message](
	[broadcast_message_id] [int] IDENTITY(1,1) NOT NULL,
	[broadcast_message_title_masterid] [int] NULL,
	[pharmacy_id] [int] NULL,
	[message] [nvarchar](3000) NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[broadcast_message_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[broadcast_message_title_master]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[broadcast_message_title_master](
	[broadcast_message_title_masterid] [int] IDENTITY(1,1) NOT NULL,
	[broadcast_message_title] [nvarchar](2000) NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[broadcast_message_title_masterid] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[broadcast_notification]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[broadcast_notification](
	[broadcast_notification_id] [int] IDENTITY(1,1) NOT NULL,
	[broadcast_message_title_masterid] [int] NULL,
	[pharmacy_id] [int] NULL,
	[is_read] [bit] NULL,
	[message] [nvarchar](3000) NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[broadcast_notification_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[carddetails]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[carddetails](
	[Id] [int] IDENTITY(1,1) NOT NULL,
	[pharmacy_id] [int] NOT NULL,
	[card_id] [nvarchar](150) NOT NULL,
	[isdeleted] [bit] NOT NULL,
	[created_on] [datetime] NULL,
	[created_by] [nvarchar](50) NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[csv_import_status]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[csv_import_status](
	[status_id] [int] IDENTITY(1,1) NOT NULL,
	[name] [nvarchar](100) NULL,
	[is_hide] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[status_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[edi_batch_details]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[edi_batch_details](
	[edi_batch_details_id] [int] IDENTITY(1,1) NOT NULL,
	[edi_batch_id] [int] NULL,
	[filename] [nvarchar](1000) NULL,
	[filetype] [nvarchar](16) NULL,
	[is_success] [bit] NULL,
	[is_error] [bit] NULL,
	[status] [nvarchar](16) NULL,
	[no_of_records] [int] NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
	[file_version] [nvarchar](16) NULL,
	[file_format] [nvarchar](24) NULL,
PRIMARY KEY CLUSTERED 
(
	[edi_batch_details_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[edi_batch_master]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[edi_batch_master](
	[edi_batch_id] [int] IDENTITY(1,1) NOT NULL,
	[pharmacy_id] [int] NULL,
	[date] [datetime] NULL,
	[no_of_files] [int] NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[edi_batch_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[edi_file_Info]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[edi_file_Info](
	[ediFile_Info_id] [int] IDENTITY(1,1) NOT NULL,
	[pharmacy_id] [int] NULL,
	[edi_batch_details_id] [int] NULL,
	[Vendor] [nvarchar](60) NULL,
	[Supplier] [nvarchar](60) NULL,
	[CatalogPurpose] [nvarchar](4) NULL,
	[InternalControlNumber] [nvarchar](4) NULL,
	[PartnerId] [nvarchar](40) NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[ediFile_Info_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[edi_inventories_status]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[edi_inventories_status](
	[status_id] [int] IDENTITY(1,1) NOT NULL,
	[name] [nvarchar](100) NULL,
	[is_hide] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[status_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[edi_inventory]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[edi_inventory](
	[edi_inventory_id] [int] IDENTITY(1,1) NOT NULL,
	[edi_batch_details_id] [int] NOT NULL,
	[pharmacy_id] [int] NULL,
	[wholesaler_id] [int] NULL,
	[status_id] [int] NOT NULL,
	[drug_name] [nvarchar](1000) NULL,
	[LIN_NDC] [nvarchar](256) NULL,
	[LIN_UPC_Num] [nvarchar](156) NULL,
	[LIN_SAP_ItemNum] [nvarchar](156) NULL,
	[LIN_MFR_PartNum] [nvarchar](156) NULL,
	[LIN_StockStatus] [nvarchar](156) NULL,
	[LIN_PVT_LabelIndicator] [nvarchar](156) NULL,
	[LIN_DropShipFlag] [nvarchar](156) NULL,
	[LIN_RepackFlag] [nvarchar](156) NULL,
	[LIN_Chemicalflag] [nvarchar](156) NULL,
	[LIN_Brand_Flag] [nvarchar](156) NULL,
	[LIN_LegacyNumber] [nvarchar](156) NULL,
	[G53_MaintTypecode] [nvarchar](64) NULL,
	[REF_ProductType] [nvarchar](64) NULL,
	[REF_CatalogCode] [nvarchar](64) NULL,
	[REF_OrangeBookCode] [nvarchar](64) NULL,
	[PID_UnitDoseIndicator] [nvarchar](64) NULL,
	[PID_UnitDose] [nvarchar](156) NULL,
	[GCN_DescType] [nvarchar](64) NULL,
	[GCN_ProductCharactersticCode] [nvarchar](64) NULL,
	[GCN_AgencyQualifierCode] [nvarchar](64) NULL,
	[GCN_class] [nvarchar](64) NULL,
	[GCN_Name] [nvarchar](156) NULL,
	[PID_Dosage_Form] [nvarchar](64) NULL,
	[PID_Dosage_Form_Code] [nvarchar](156) NULL,
	[PID_StrengthCode] [nvarchar](64) NULL,
	[PID_Strength] [nvarchar](156) NULL,
	[PID_ProductColorCode] [nvarchar](64) NULL,
	[PID_ProductColor] [nvarchar](80) NULL,
	[PO4_Pack_MetricSize] [nvarchar](64) NULL,
	[PO4_Pack_FDBSize] [nvarchar](64) NULL,
	[PO4_Pack_code] [nvarchar](64) NULL,
	[REF_FL] [nvarchar](156) NULL,
	[REF_FL_HamacherCode] [nvarchar](64) NULL,
	[TD4_HM_Code] [nvarchar](64) NULL,
	[TD4_SRG_Qualifier] [nvarchar](64) NULL,
	[TD4_SRG_Code] [nvarchar](156) NULL,
	[CTP_AWP] [nvarchar](64) NULL,
	[CTP_AWF] [nvarchar](64) NULL,
	[DTM_SWP_EffectiveDate] [nvarchar](64) NULL,
	[REF_Quote_ContractId] [nvarchar](64) NULL,
	[REF_Quote_ContractName] [nvarchar](156) NULL,
	[CTP_ListPrice] [nvarchar](64) NULL,
	[DTM_LP_EffectiveDate] [nvarchar](64) NULL,
	[CTP_MSR_Price] [nvarchar](64) NULL,
	[CTP_MSR_ConditionValue] [nvarchar](64) NULL,
	[CTP_RTL_Price] [nvarchar](64) NULL,
	[CTP_RTL_Quantity] [nvarchar](64) NULL,
	[CTP_RTL_MeasurementUnit] [nvarchar](64) NULL,
	[CTP_WHL_Cost] [nvarchar](64) NULL,
	[DTM_WHL_ED] [nvarchar](64) NULL,
	[CTP_INV_AcqCost] [nvarchar](64) NULL,
	[CTP_INV_Quantity] [nvarchar](64) NULL,
	[CTP_INV_UnitCode] [nvarchar](64) NULL,
	[CTP_INV_Unit] [nvarchar](64) NULL,
	[CTP_CON_Cost] [nvarchar](156) NULL,
	[CTP_CON_Quantity] [nvarchar](64) NULL,
	[CTP_CON_Unit] [nvarchar](64) NULL,
	[DTM_CON_Effective] [nvarchar](64) NULL,
	[DTM_CON_Expire] [nvarchar](64) NULL,
	[DTM_Acquisition_ED] [nvarchar](64) NULL,
	[CTP_QTE_Price] [nvarchar](64) NULL,
	[N1_SU_Name] [nvarchar](156) NULL,
	[N1_SU_Code] [nvarchar](64) NULL,
	[N1_SU_VN_Number] [nvarchar](156) NULL,
	[G39_WSP] [nvarchar](156) NULL,
	[G39_RPack_Quantity] [nvarchar](64) NULL,
	[G39_RPack_Size] [nvarchar](64) NULL,
	[G39_RPack_Unit] [nvarchar](64) NULL,
	[dea] [nvarchar](512) NULL,
	[tax] [decimal](5, 2) NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[edi_inventory_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[edi_server_configuration]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[edi_server_configuration](
	[edi_config_id] [int] IDENTITY(1,1) NOT NULL,
	[wholeseller_id] [int] NOT NULL,
	[username] [nvarchar](156) NOT NULL,
	[password] [nvarchar](156) NOT NULL,
	[port] [int] NOT NULL,
	[host] [nvarchar](256) NOT NULL,
	[documentpath] [nvarchar](256) NOT NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[is_deleted] [bit] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[IsActive] [bit] NOT NULL,
	[edi_account_number] [nvarchar](500) NULL,
PRIMARY KEY CLUSTERED 
(
	[edi_config_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[FDB_DataUpdate_Log]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[FDB_DataUpdate_Log](
	[Id] [int] IDENTITY(1,1) NOT NULL,
	[FileType] [nvarchar](500) NULL,
	[Data_Update_DT] [datetime] NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[FDB_Package]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[FDB_Package](
	[Pack_Id] [int] IDENTITY(1,1) NOT NULL,
	[PRODUCTID] [nvarchar](500) NULL,
	[PRODUCTNDC] [nvarchar](250) NULL,
	[NDCPACKAGECODE] [nvarchar](250) NULL,
	[PACKAGEDESCRIPTION] [nvarchar](max) NULL,
	[ProductQuantity] [nvarchar](max) NULL,
	[STARTMARKETINGDATE] [nvarchar](250) NULL,
	[ENDMARKETINGDATE] [nvarchar](250) NULL,
	[NDC_EXCLUDE_FLAG] [nvarchar](max) NULL,
	[SAMPLE_PACKAGE] [nvarchar](max) NULL,
	[PackageCode] [int] NULL,
	[NDCINT] [bigint] NULL,
PRIMARY KEY CLUSTERED 
(
	[Pack_Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
/****** Object:  Table [dbo].[FDB_Product]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[FDB_Product](
	[P_Id] [int] IDENTITY(1,1) NOT NULL,
	[PRODUCTID] [nvarchar](max) NOT NULL,
	[PRODUCTNDC] [nvarchar](max) NULL,
	[PRODUCTTYPENAME] [nvarchar](max) NULL,
	[PROPRIETARYNAME] [nvarchar](max) NULL,
	[PROPRIETARYNAMESUFFIX] [nvarchar](max) NULL,
	[NONPROPRIETARYNAME] [nvarchar](max) NULL,
	[DOSAGEFORMNAME] [nvarchar](max) NULL,
	[ROUTENAME] [nvarchar](max) NULL,
	[STARTMARKETINGDATE] [nvarchar](500) NULL,
	[ENDMARKETINGDATE] [nvarchar](500) NULL,
	[MARKETINGCATEGORYNAME] [nvarchar](max) NULL,
	[APPLICATIONNUMBER] [nvarchar](max) NULL,
	[LABELERNAME] [nvarchar](max) NULL,
	[SUBSTANCENAME] [nvarchar](max) NULL,
	[ACTIVE_NUMERATOR_STRENGTH] [nvarchar](max) NULL,
	[ACTIVE_INGRED_UNIT] [nvarchar](max) NULL,
	[PHARM_CLASSES] [nvarchar](max) NULL,
	[DEASCHEDULE] [nvarchar](max) NULL,
	[NDC_EXCLUDE_FLAG] [nvarchar](250) NULL,
	[LISTING_RECORD_CERTIFIED_THROUGH] [nvarchar](1000) NULL,
PRIMARY KEY CLUSTERED 
(
	[P_Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
/****** Object:  Table [dbo].[Inv_Exp_Config]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[Inv_Exp_Config](
	[config_id] [int] IDENTITY(1,1) NOT NULL,
	[Is_deleted] [bit] NULL,
	[expiry_month] [int] NOT NULL,
PRIMARY KEY CLUSTERED 
(
	[config_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[inventory]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[inventory](
	[inventory_id] [int] IDENTITY(1,1) NOT NULL,
	[pharmacy_id] [int] NULL,
	[wholesaler_id] [int] NULL,
	[drug_name] [nvarchar](1000) NULL,
	[ndc] [bigint] NULL,
	[generic_code] [bigint] NULL,
	[dea] [bigint] NULL,
	[obc] [nvarchar](500) NULL,
	[dfc] [bigint] NULL,
	[doctor_npi] [bigint] NULL,
	[qty_pres] [decimal](18, 0) NULL,
	[qty_disp] [decimal](18, 0) NULL,
	[origin] [bigint] NULL,
	[pi] [nvarchar](100) NULL,
	[plan_id] [nvarchar](1000) NULL,
	[bin] [bigint] NULL,
	[pcn] [nvarchar](100) NULL,
	[uandc] [decimal](18, 0) NULL,
	[ingrd_cost] [money] NULL,
	[plan_paid] [money] NULL,
	[pat_paid] [money] NULL,
	[rx_cost] [money] NULL,
	[tax] [decimal](18, 0) NULL,
	[price] [money] NULL,
	[response] [nvarchar](100) NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
	[license] [int] NULL,
	[pharmacy_name] [nvarchar](1000) NULL,
	[contact] [nvarchar](1000) NULL,
	[status] [int] NULL,
	[opened] [bit] NULL,
	[damaged] [bit] NULL,
	[non_c2] [bit] NULL,
	[batch_id] [int] NULL,
	[inventory_source_id] [int] NULL,
	[Strength] [nvarchar](100) NULL,
	[LotNumber] [nvarchar](100) NULL,
	[NDC_Packsize] [decimal](10, 2) NULL,
	[expiry_date] [datetime] NULL,
	[pack_size] [decimal](10, 2) NULL,
PRIMARY KEY CLUSTERED 
(
	[inventory_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[inventory_backup18062018]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[inventory_backup18062018](
	[inventory_id] [int] IDENTITY(1,1) NOT NULL,
	[pharmacy_id] [int] NULL,
	[wholesaler_id] [int] NULL,
	[drug_name] [nvarchar](1000) NULL,
	[ndc] [bigint] NULL,
	[generic_code] [bigint] NULL,
	[dea] [bigint] NULL,
	[obc] [nvarchar](500) NULL,
	[dfc] [bigint] NULL,
	[doctor_npi] [bigint] NULL,
	[qty_pres] [decimal](18, 0) NULL,
	[qty_disp] [decimal](18, 0) NULL,
	[origin] [bigint] NULL,
	[pi] [nvarchar](100) NULL,
	[plan_id] [nvarchar](1000) NULL,
	[bin] [bigint] NULL,
	[pcn] [nvarchar](100) NULL,
	[uandc] [decimal](18, 0) NULL,
	[ingrd_cost] [money] NULL,
	[plan_paid] [money] NULL,
	[pat_paid] [money] NULL,
	[rx_cost] [money] NULL,
	[tax] [decimal](18, 0) NULL,
	[price] [money] NULL,
	[response] [nvarchar](100) NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
	[license] [int] NULL,
	[pharmacy_name] [nvarchar](1000) NULL,
	[contact] [nvarchar](1000) NULL,
	[status] [int] NULL,
	[opened] [bit] NULL,
	[damaged] [bit] NULL,
	[non_c2] [bit] NULL,
	[batch_id] [int] NULL,
	[inventory_source_id] [int] NULL,
	[Strength] [nvarchar](100) NULL,
	[LotNumber] [nvarchar](100) NULL,
	[NDC_Packsize] [decimal](10, 2) NULL,
	[expiry_date] [datetime] NULL,
	[pack_size] [decimal](10, 2) NULL
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[inventory_source_master]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[inventory_source_master](
	[inventory_source_master_id] [int] IDENTITY(1,1) NOT NULL,
	[source_name] [nvarchar](1000) NULL,
	[is_hide] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[inventory_source_master_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[invoice]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[invoice](
	[invoice_id] [int] IDENTITY(1,1) NOT NULL,
	[invoice_number] [nvarchar](1000) NULL,
	[invoice_date] [datetime] NULL,
	[purchase_order_date] [datetime] NULL,
	[purchase_order_number] [nvarchar](24) NULL,
	[transaction_type_code] [nvarchar](4) NULL,
	[invoiced_lineItem] [nvarchar](16) NULL,
	[shipped_lineItems] [nvarchar](16) NULL,
	[monetary_amount] [nvarchar](16) NULL,
	[pharmacy_id] [int] NULL,
	[order_id] [int] NULL,
	[invoice_status_id] [int] NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
	[edi_batch_details_id] [int] NOT NULL,
	[WholesalerId] [int] NOT NULL,
	[status] [nvarchar](20) NULL,
PRIMARY KEY CLUSTERED 
(
	[invoice_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[invoice_additionalItem]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[invoice_additionalItem](
	[invoice_addionalitem_id] [int] IDENTITY(1,1) NOT NULL,
	[invoice_items_id] [int] NOT NULL,
	[item_order_status] [nvarchar](4) NULL,
	[remaining_quantity] [nvarchar](16) NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[invoice_addionalitem_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[invoice_billcontacts]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[invoice_billcontacts](
	[contactinfo_id] [int] IDENTITY(1,1) NOT NULL,
	[invoice_billing_id] [int] NOT NULL,
	[contact_function_code] [nvarchar](16) NULL,
	[commu_number_qual] [nvarchar](16) NULL,
	[phone_number] [nvarchar](24) NULL,
	[created_on] [datetime] NULL,
PRIMARY KEY CLUSTERED 
(
	[contactinfo_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[invoice_billing_details]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[invoice_billing_details](
	[invoice_billing_id] [int] IDENTITY(1,1) NOT NULL,
	[invoice_id] [int] NOT NULL,
	[name] [nvarchar](500) NULL,
	[party_identifier] [nvarchar](16) NULL,
	[party_id] [nvarchar](100) NULL,
	[address01] [nvarchar](64) NULL,
	[address02] [nvarchar](64) NULL,
	[city_name] [nvarchar](64) NULL,
	[province_name] [nvarchar](10) NULL,
	[postal_code] [nvarchar](64) NULL,
	[created_on] [datetime] NULL,
PRIMARY KEY CLUSTERED 
(
	[invoice_billing_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[invoice_line_items]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[invoice_line_items](
	[invoice_lineitem_id] [int] IDENTITY(1,1) NOT NULL,
	[invoice_id] [int] NOT NULL,
	[invoiced_quantity] [nvarchar](16) NULL,
	[unit] [nvarchar](16) NULL,
	[unit_price] [money] NULL,
	[ndc_upc] [nvarchar](64) NULL,
	[product_qual] [nvarchar](8) NULL,
	[seller_qual] [nvarchar](8) NULL,
	[seller_number] [nvarchar](64) NULL,
	[buyer_qual] [nvarchar](8) NULL,
	[buyer_item_number] [nvarchar](64) NULL,
	[prodtype_qual] [nvarchar](8) NULL,
	[prodtype_number] [nvarchar](64) NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[invoice_lineitem_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[invoice_productDescription]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[invoice_productDescription](
	[invoice_product_id] [int] IDENTITY(1,1) NOT NULL,
	[invoice_items_id] [int] NOT NULL,
	[agency_qual_code] [nvarchar](4) NULL,
	[product_desc_code] [nvarchar](16) NULL,
	[product_desc] [nvarchar](125) NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[invoice_product_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[invoice_SAC]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[invoice_SAC](
	[invoice_sac_id] [int] IDENTITY(1,1) NOT NULL,
	[invoice_items_id] [int] NOT NULL,
	[sac_indicator] [nvarchar](4) NULL,
	[sac_code] [nvarchar](16) NULL,
	[sac_amount] [nvarchar](16) NULL,
	[sac_description] [nvarchar](156) NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[invoice_sac_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[invoice_shipping_details]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[invoice_shipping_details](
	[invoice_shipping_id] [int] IDENTITY(1,1) NOT NULL,
	[invoice_id] [int] NOT NULL,
	[shipto_name] [nvarchar](500) NULL,
	[party_identifier] [nvarchar](64) NULL,
	[sap_number] [nvarchar](80) NULL,
	[shipto_address] [nvarchar](55) NULL,
	[shipto_city_name] [nvarchar](64) NULL,
	[shipto_province_name] [nvarchar](64) NULL,
	[shipto_postal_code] [nvarchar](64) NULL,
	[ref_identifier] [nvarchar](64) NULL,
	[ref_number] [nvarchar](64) NULL,
	[created_on] [datetime] NULL,
PRIMARY KEY CLUSTERED 
(
	[invoice_shipping_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[invoice_taxes]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[invoice_taxes](
	[invoice_tax_id] [int] IDENTITY(1,1) NOT NULL,
	[invoice_id] [int] NOT NULL,
	[tax_type] [nvarchar](4) NULL,
	[tax_monetory_amount] [nvarchar](24) NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[invoice_tax_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[Log]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[Log](
	[Id] [int] IDENTITY(1,1) NOT NULL,
	[Application] [nvarchar](50) NOT NULL,
	[Logged] [datetime] NOT NULL,
	[Level] [nvarchar](50) NOT NULL,
	[Message] [nvarchar](max) NOT NULL,
	[UserName] [nvarchar](250) NULL,
	[Logger] [nvarchar](250) NULL,
	[Callsite] [nvarchar](max) NULL,
	[Exception] [nvarchar](max) NULL,
	[InnerException] [nvarchar](max) NULL,
	[StackTrace] [nvarchar](max) NULL,
	[Controller] [nvarchar](256) NULL,
	[Action] [nvarchar](256) NULL,
	[Url] [nvarchar](500) NULL,
 CONSTRAINT [PK_dbo.Log] PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
/****** Object:  Table [dbo].[LogUserActivity]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[LogUserActivity](
	[LOGID] [int] IDENTITY(1,1) NOT NULL,
	[USERNAME] [nvarchar](500) NULL,
	[IP_ADDRESS] [nvarchar](256) NULL,
	[ROUTEDATA] [nvarchar](500) NULL,
	[ACTIVITY_RECORDED_DTM] [datetime] NULL,
	[CONTROLLER] [nvarchar](256) NULL,
 CONSTRAINT [PK_LOG_ID] PRIMARY KEY CLUSTERED 
(
	[LOGID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[marketplace_drugpost_notification]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[marketplace_drugpost_notification](
	[marketplace_drugpost_notification_id] [int] IDENTITY(1,1) NOT NULL,
	[mp_postitem_id] [int] NULL,
	[pharmacy_id] [int] NULL,
	[is_read] [bit] NULL,
	[message] [nvarchar](3000) NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[is_deleted] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[marketplace_drugpost_notification_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[marketplace_drugpurchase_notification]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[marketplace_drugpurchase_notification](
	[marketplace_drugpurchase_notification_id] [int] IDENTITY(1,1) NOT NULL,
	[mp_postitem_id] [int] NULL,
	[sellerpharmacy_id] [int] NULL,
	[purchaser_pharmacy_id] [int] NULL,
	[is_read] [bit] NULL,
	[message] [nvarchar](3000) NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[is_deleted] [bit] NULL,
	[Transfer_Mgt_Id] [bigint] NULL,
PRIMARY KEY CLUSTERED 
(
	[marketplace_drugpurchase_notification_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[master_city]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[master_city](
	[city_id] [int] NOT NULL,
	[state_id] [int] NULL,
	[city_name] [nvarchar](100) NULL,
	[hide] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[city_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[master_country]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[master_country](
	[countryid] [int] NOT NULL,
	[sortname] [nvarchar](10) NULL,
	[country_name] [nvarchar](100) NULL,
	[phonecode] [int] NULL,
	[hide] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[countryid] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[master_gender]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[master_gender](
	[gender_id] [int] NOT NULL,
	[gender_name] [nvarchar](50) NULL,
	[hide] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[gender_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[master_marital_status]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[master_marital_status](
	[maritalstatus_id] [int] NOT NULL,
	[status_name] [nvarchar](50) NULL,
	[hide] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[maritalstatus_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[master_state]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[master_state](
	[state_id] [int] NOT NULL,
	[state_name] [nvarchar](100) NULL,
	[countryid] [int] NULL,
	[hide] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[state_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[medicine]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[medicine](
	[medicine_id] [int] IDENTITY(1,1) NOT NULL,
	[drug_name] [nvarchar](1000) NULL,
	[ndc_code] [bigint] NULL,
	[generic_code] [bigint] NULL,
	[description] [nvarchar](1000) NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
	[pharmacy_id] [int] NULL,
PRIMARY KEY CLUSTERED 
(
	[medicine_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[mp_network_type]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[mp_network_type](
	[mp_network_type_id] [int] IDENTITY(1,1) NOT NULL,
	[network_name] [nvarchar](1000) NULL,
	[is_hide] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[mp_network_type_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[mp_post_items]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[mp_post_items](
	[mp_postitem_id] [int] IDENTITY(1,1) NOT NULL,
	[mp_network_type_id] [int] NULL,
	[drug_name] [nvarchar](1000) NULL,
	[ndc_code] [bigint] NULL,
	[generic_code] [bigint] NULL,
	[pack_size] [decimal](18, 2) NULL,
	[strength] [nvarchar](1000) NULL,
	[base_price] [money] NULL,
	[lot_number] [nvarchar](1000) NULL,
	[exipry_date] [datetime] NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
	[sales_price] [money] NULL,
	[pharmacy_id] [int] NULL,
 CONSTRAINT [PK__mp_post___7DD18FE40C98A34D] PRIMARY KEY CLUSTERED 
(
	[mp_postitem_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[order_details]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[order_details](
	[order_details_id] [int] IDENTITY(1,1) NOT NULL,
	[order_id] [int] NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
	[medicine_id] [int] NULL,
	[drugname] [nvarchar](1000) NULL,
	[ndc] [bigint] NULL,
	[price] [money] NULL,
	[ndc_packsize] [decimal](10, 2) NULL,
	[damaged] [bit] NULL,
	[non_c2] [bit] NULL,
	[opened] [bit] NULL,
	[expiry_date] [datetime] NULL,
	[lot_number] [nvarchar](500) NULL,
	[strength] [nvarchar](500) NULL,
	[quantity] [decimal](10, 2) NULL,
PRIMARY KEY CLUSTERED 
(
	[order_details_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[orders]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[orders](
	[order_id] [int] IDENTITY(1,1) NOT NULL,
	[pharmacy_id] [int] NULL,
	[wholesaler_id] [int] NULL,
	[order_status_id] [int] NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[order_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[payments]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[payments](
	[paymentId] [int] IDENTITY(1,1) NOT NULL,
	[pharmacy_id] [int] NOT NULL,
	[amount] [decimal](8, 2) NULL,
	[chargeId] [nvarchar](500) NULL,
	[status] [nvarchar](50) NULL,
	[IsPaid] [bit] NULL,
	[IsCaptured] [bit] NULL,
	[created_on] [datetime] NULL,
	[created_by] [nvarchar](50) NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[chargeCreated] [datetime] NULL,
	[customerId] [nvarchar](1000) NULL,
PRIMARY KEY CLUSTERED 
(
	[paymentId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[pending_reorder]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[pending_reorder](
	[pending_reorder_id] [int] IDENTITY(1,1) NOT NULL,
	[ndc] [bigint] NULL,
	[qty_reorder] [decimal](10, 3) NULL,
	[pharmacy_id] [int] NULL,
	[rx30_inventory_id] [int] NULL,
	[rx30_batch_details_id] [int] NULL,
	[inventory_id] [int] NULL,
	[created_on] [datetime] NULL,
PRIMARY KEY CLUSTERED 
(
	[pending_reorder_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[pending_reorder_log]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[pending_reorder_log](
	[pending_reorder_log_id] [int] IDENTITY(1,1) NOT NULL,
	[pending_reorder_id] [int] NULL,
	[ndc] [bigint] NULL,
	[received_quantity] [decimal](10, 3) NULL,
	[pending_quantity] [decimal](10, 3) NULL,
	[received_quantity_reset] [decimal](10, 3) NULL,
	[pending_quantity_reset] [decimal](10, 3) NULL,
	[pharmacy_id] [int] NULL,
	[created_on] [datetime] NULL,
PRIMARY KEY CLUSTERED 
(
	[pending_reorder_log_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[ph_messageboard]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[ph_messageboard](
	[messageboard_id] [int] IDENTITY(1,1) NOT NULL,
	[from_ph_id] [int] NULL,
	[to_ph_id] [int] NULL,
	[message] [nvarchar](4000) NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
	[status] [nvarchar](50) NULL,
PRIMARY KEY CLUSTERED 
(
	[messageboard_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[pharmacy_business_profile]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[pharmacy_business_profile](
	[business_profile_id] [int] IDENTITY(1,1) NOT NULL,
	[pharmacy_id] [int] NULL,
	[business_address] [nvarchar](max) NULL,
	[business_contact] [nvarchar](max) NULL,
	[logo] [nvarchar](1000) NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[business_profile_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
/****** Object:  Table [dbo].[pharmacy_invoice_status_master]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[pharmacy_invoice_status_master](
	[invoice_status_id] [int] IDENTITY(1,1) NOT NULL,
	[status_name] [nvarchar](1000) NULL,
	[is_hide] [bit] NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[invoice_status_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[pharmacy_list]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[pharmacy_list](
	[pharmacy_id] [int] IDENTITY(1,1) NOT NULL,
	[pharmacy_name] [nvarchar](2000) NULL,
	[license_number] [nvarchar](2000) NULL,
	[tax_id] [nvarchar](1000) NULL,
	[notes] [nvarchar](max) NULL,
	[contact_person] [nvarchar](2000) NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
	[pharmacy_owner_id] [int] NULL,
	[pharmacy_logo] [nvarchar](100) NULL,
	[registrationdate] [datetime] NULL,
	[subscription_status] [nvarchar](100) NULL,
	[contact_no] [nvarchar](50) NULL,
	[mobile_no] [nvarchar](50) NULL,
	[UserId] [int] NULL,
	[subscription_plan_id] [int] NULL,
	[Email] [nvarchar](100) NULL,
	[PlanExpireDT] [datetime] NULL,
PRIMARY KEY CLUSTERED 
(
	[pharmacy_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
/****** Object:  Table [dbo].[pharmacy_module_master]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[pharmacy_module_master](
	[pharmacy_module_id] [int] IDENTITY(1,1) NOT NULL,
	[module_name] [nvarchar](1000) NULL,
	[is_hide] [bit] NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[pharmacy_module_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[pharmacy_notification_setting]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[pharmacy_notification_setting](
	[notification_setting_id] [int] IDENTITY(1,1) NOT NULL,
	[pharmacy_id] [int] NULL,
	[is_hide_read_messages] [bit] NULL,
	[is_notify_me_on_mail] [bit] NULL,
	[is_notify_me_on_phone] [bit] NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[notification_setting_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[pharmacy_order_status_master]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[pharmacy_order_status_master](
	[order_status_id] [int] IDENTITY(1,1) NOT NULL,
	[status_name] [nvarchar](1000) NULL,
	[is_hide] [bit] NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[order_status_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[pharmacy_report_setting]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[pharmacy_report_setting](
	[pharmacy_reprot_setting_id] [int] IDENTITY(1,1) NOT NULL,
	[pharmacy_id] [int] NULL,
	[logo] [nvarchar](1000) NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[pharmacy_reprot_setting_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[pharmacy_role_module_assignment]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[pharmacy_role_module_assignment](
	[pharmacy_role_module_assignment_id] [int] IDENTITY(1,1) NOT NULL,
	[role_id] [int] NULL,
	[module_id] [int] NULL,
	[is_deletd] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[pharmacy_role_module_assignment_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[pharmacy_ups_account]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[pharmacy_ups_account](
	[pharmacy_ups_account_id] [int] IDENTITY(1,1) NOT NULL,
	[pharmacy_id] [int] NULL,
	[username] [nvarchar](500) NULL,
	[password] [nvarchar](500) NULL,
	[accesslicensenumber] [nvarchar](500) NULL,
	[name] [nvarchar](500) NULL,
	[addressline] [nvarchar](500) NULL,
	[city] [nvarchar](500) NULL,
	[statecode] [nvarchar](500) NULL,
	[postalcode] [nvarchar](500) NULL,
	[phonenumber] [nvarchar](500) NULL,
	[upsaccountnumber] [nvarchar](1000) NULL,
PRIMARY KEY CLUSTERED 
(
	[pharmacy_ups_account_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[pharmacy_users]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[pharmacy_users](
	[pharmacy_user_id] [int] IDENTITY(1,1) NOT NULL,
	[pharmacy_id] [int] NULL,
	[first_name] [nvarchar](1000) NULL,
	[middle_name] [nvarchar](1000) NULL,
	[last_name] [nvarchar](1000) NULL,
	[email] [nvarchar](1000) NULL,
	[username] [nvarchar](1000) NULL,
	[password] [nvarchar](1000) NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
	[pharmacy_user_role_id] [int] NULL,
PRIMARY KEY CLUSTERED 
(
	[pharmacy_user_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[pharmacy_users_roles_assignment]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[pharmacy_users_roles_assignment](
	[pharmacy_user_roles_assignment_id] [int] IDENTITY(1,1) NOT NULL,
	[pharmacy_user_id] [int] NULL,
	[pharmacy_user_role_id] [int] NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[pharmacy_user_roles_assignment_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[pharmacy_users_roles_master]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[pharmacy_users_roles_master](
	[pharmacy_user_role_id] [int] IDENTITY(1,1) NOT NULL,
	[role_name] [nvarchar](1000) NULL,
	[is_hide] [bit] NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
 CONSTRAINT [PK__pharmacy__5712DD9573FB1431] PRIMARY KEY CLUSTERED 
(
	[pharmacy_user_role_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[pre_shippmentorder]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[pre_shippmentorder](
	[pre_shippmentorder_id] [int] IDENTITY(1,1) NOT NULL,
	[mp_postitem_id] [int] NULL,
	[quantity] [int] NULL,
	[purchaser_pharmacy_id] [int] NULL,
	[seller_pharmacy_id] [int] NULL,
	[created_by] [int] NULL,
	[created_on] [datetime] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[is_deletd] [bit] NULL,
	[deleted_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[shipping_status_master_id] [int] NULL,
	[shipping_method_id] [int] NULL,
PRIMARY KEY CLUSTERED 
(
	[pre_shippmentorder_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[return_to_wholesaler_items]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[return_to_wholesaler_items](
	[item_id] [bigint] IDENTITY(1,1) NOT NULL,
	[returntowholesaler_Id] [bigint] NULL,
	[inventory_id] [bigint] NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[is_deleted] [bit] NOT NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[drug_name] [nvarchar](150) NULL,
	[wholesaler_name] [nvarchar](150) NULL,
	[ndc] [bigint] NULL,
	[quantity] [decimal](18, 0) NULL,
	[amount] [money] NULL,
	[expiry_date] [datetime] NULL,
	[lot_number] [nvarchar](150) NULL,
	[wholesaler_id] [int] NULL,
	[pharmacy_id] [int] NULL,
PRIMARY KEY CLUSTERED 
(
	[item_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[returnalert]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[returnalert](
	[alert_Id] [bigint] IDENTITY(1,1) NOT NULL,
	[pharmacy_id] [int] NULL,
	[alert_date] [datetime] NULL,
	[created_by] [int] NULL,
	[created_on] [datetime] NULL,
	[is_deleted] [bit] NULL,
	[deleted_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[drug_InventoryId] [int] NULL,
	[description] [nvarchar](2000) NULL,
	[is_read] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[alert_Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[Returns]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[Returns](
	[ReturnId] [int] IDENTITY(1,1) NOT NULL,
	[PharmacyId] [int] NULL,
	[WholesalerId] [int] NULL,
	[DrugName] [nvarchar](1000) NULL,
	[Quantity] [decimal](18, 0) NULL,
	[Price] [decimal](18, 0) NULL,
	[NDC] [bigint] NULL,
	[GenericCode] [bigint] NULL,
	[Created_on] [datetime] NULL,
	[Created_by] [int] NULL,
	[Updated_by] [int] NULL,
	[Updated_on] [datetime] NULL,
	[is_deleted] [bit] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
PRIMARY KEY CLUSTERED 
(
	[ReturnId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[ReturnToWholesaler]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[ReturnToWholesaler](
	[returntowholesaler_Id] [bigint] IDENTITY(1,1) NOT NULL,
	[created_by] [int] NULL,
	[created_on] [datetime] NULL,
	[is_deleted] [bit] NULL,
	[deleted_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[pharmacy_id] [bigint] NULL,
PRIMARY KEY CLUSTERED 
(
	[returntowholesaler_Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[Roles]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[Roles](
	[Id] [int] IDENTITY(100,1) NOT NULL,
	[Role] [nvarchar](256) NULL,
	[IsActive] [bit] NOT NULL,
	[IsDeleted] [bit] NOT NULL,
 CONSTRAINT [PK_Roles] PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[rx30_batch_details]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[rx30_batch_details](
	[rx30_batch_details_id] [int] IDENTITY(1,1) NOT NULL,
	[rx30_batch_id] [int] NULL,
	[filename] [nvarchar](1000) NULL,
	[is_success] [bit] NULL,
	[is_error] [bit] NULL,
	[no_of_records] [int] NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[rx30_batch_details_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[rx30_batch_master]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[rx30_batch_master](
	[rx30_batch_id] [int] IDENTITY(1,1) NOT NULL,
	[pharmacy_id] [int] NULL,
	[date] [datetime] NULL,
	[no_of_files] [int] NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
	[pharmacy_name] [nvarchar](1000) NULL,
	[directory_path] [nvarchar](1000) NULL,
PRIMARY KEY CLUSTERED 
(
	[rx30_batch_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[rx30_configfolderpath]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[rx30_configfolderpath](
	[rx30_configfolderpath_id] [int] IDENTITY(1,1) NOT NULL,
	[pharmacy_id] [int] NULL,
	[pharmacy_name] [nvarchar](1000) NULL,
	[directory_path] [nvarchar](1000) NULL,
	[is_active] [bit] NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[rx30_configfolderpath_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[RX30_inventory]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[RX30_inventory](
	[rx30_inventory_id] [int] IDENTITY(1,1) NOT NULL,
	[pharmacy_id] [int] NULL,
	[wholesaler_id] [int] NULL,
	[rx30_batch_details_id] [int] NULL,
	[drug_name] [nvarchar](1000) NULL,
	[ndc] [bigint] NULL,
	[generic_code] [nvarchar](1000) NULL,
	[dea] [bigint] NULL,
	[obc] [nvarchar](500) NULL,
	[dfc] [bigint] NULL,
	[pack_size] [money] NULL,
	[doctor_npi] [bigint] NULL,
	[qty_pres] [money] NULL,
	[qty_disp] [money] NULL,
	[origin] [bigint] NULL,
	[pi] [nvarchar](100) NULL,
	[plan_id] [nvarchar](1000) NULL,
	[bin] [bigint] NULL,
	[pcn] [nvarchar](100) NULL,
	[uandc] [money] NULL,
	[ingrd_cost] [money] NULL,
	[plan_paid] [money] NULL,
	[pat_paid] [money] NULL,
	[rx_cost] [money] NULL,
	[tax] [money] NULL,
	[price] [money] NULL,
	[response] [nvarchar](100) NULL,
	[is_success] [bit] NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
	[license] [int] NULL,
	[pharmacy_name] [nvarchar](1000) NULL,
	[contact] [nvarchar](1000) NULL,
	[status] [int] NULL,
	[pbp] [nvarchar](1000) NULL,
	[plan_name] [nvarchar](1000) NULL,
	[awp] [money] NULL,
PRIMARY KEY CLUSTERED 
(
	[rx30_inventory_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[rx30_status_master]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[rx30_status_master](
	[status_id] [int] IDENTITY(1,1) NOT NULL,
	[status_name] [nvarchar](1000) NULL,
	[is_hide] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[status_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[sa_invoice_payment_details]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[sa_invoice_payment_details](
	[invoice_payment_id] [int] IDENTITY(1,1) NOT NULL,
	[superadmin_invoice_id] [int] NULL,
	[ip_date] [datetime] NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[is_deleted] [bit] NOT NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
PRIMARY KEY CLUSTERED 
(
	[invoice_payment_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[sa_pharmacy_owner]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
SET ANSI_PADDING ON
GO
CREATE TABLE [dbo].[sa_pharmacy_owner](
	[pharmacy_owner_id] [int] IDENTITY(1,1) NOT NULL,
	[first_name] [nvarchar](50) NULL,
	[last_name] [nvarchar](50) NULL,
	[middle_name] [nvarchar](50) NULL,
	[gender] [int] NULL,
	[contact_no] [nvarchar](50) NULL,
	[email] [nvarchar](70) NULL,
	[dob] [datetime] NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[is_deleted] [bit] NOT NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[pharmacy_name] [varchar](100) NULL,
PRIMARY KEY CLUSTERED 
(
	[pharmacy_owner_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_PADDING OFF
GO
/****** Object:  Table [dbo].[sa_pharmacy_subscription]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[sa_pharmacy_subscription](
	[pharmacy_subscription_id] [int] IDENTITY(1,1) NOT NULL,
	[subscription_plan_id] [int] NULL,
	[s_status] [int] NULL,
	[s_date] [datetime] NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[is_deleted] [bit] NOT NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
PRIMARY KEY CLUSTERED 
(
	[pharmacy_subscription_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[sa_subscription_plan]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[sa_subscription_plan](
	[subscription_plan_id] [int] IDENTITY(1,1) NOT NULL,
	[plan_name] [nvarchar](100) NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[is_deleted] [bit] NOT NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[months] [int] NULL,
	[status] [nvarchar](50) NULL,
	[features] [nvarchar](3000) NULL,
	[description] [nvarchar](3000) NULL,
	[cost] [decimal](10, 3) NULL,
PRIMARY KEY CLUSTERED 
(
	[subscription_plan_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[sa_superadmin_invoice]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[sa_superadmin_invoice](
	[superadmin_invoice_id] [int] IDENTITY(1,1) NOT NULL,
	[invoice_no] [nvarchar](50) NULL,
	[subscription_plan_id] [int] NULL,
	[i_status] [nvarchar](50) NULL,
	[subscription_amount] [nvarchar](50) NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[is_deleted] [bit] NOT NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[pharmacy_id] [int] NULL,
PRIMARY KEY CLUSTERED 
(
	[superadmin_invoice_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[sa_superAdmin_sddress]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[sa_superAdmin_sddress](
	[superadmin_address_id] [int] IDENTITY(1,1) NOT NULL,
	[pharmacy_owner_id] [int] NULL,
	[address_line_1] [nvarchar](150) NULL,
	[address_line_2] [nvarchar](150) NULL,
	[country_id] [int] NULL,
	[state_id] [int] NULL,
	[city_id] [int] NULL,
	[zipcode] [nvarchar](10) NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[is_deleted] [bit] NOT NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[pharmacy_id] [int] NULL,
	[city] [nvarchar](500) NULL,
PRIMARY KEY CLUSTERED 
(
	[superadmin_address_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[shipping_methods]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[shipping_methods](
	[shipping_method_id] [int] IDENTITY(1,1) NOT NULL,
	[Name] [nvarchar](1000) NULL,
	[Description] [nvarchar](1000) NULL,
	[created_on] [datetime] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[shipping_method_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[shipping_status_master]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[shipping_status_master](
	[shipping_status_master_id] [int] IDENTITY(1,1) NOT NULL,
	[status_name] [nvarchar](1000) NULL,
	[is_hide] [bit] NULL,
	[Description] [nvarchar](2000) NULL,
PRIMARY KEY CLUSTERED 
(
	[shipping_status_master_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[shippment]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
SET ANSI_PADDING ON
GO
CREATE TABLE [dbo].[shippment](
	[shippment_id] [int] IDENTITY(1,1) NOT NULL,
	[shipping_cost] [decimal](10, 2) NULL,
	[package_weight] [decimal](10, 2) NULL,
	[tracking_number] [nvarchar](100) NULL,
	[shipping_method] [nvarchar](500) NULL,
	[purchaser_pharmacy_id] [int] NULL,
	[seller_pharmacy_id] [int] NULL,
	[shipping_status_master_id] [int] NULL,
	[created_by] [int] NULL,
	[created_on] [datetime] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[is_deletd] [bit] NULL,
	[deleted_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[total_cost] [decimal](10, 2) NULL,
	[fromPharmacyName] [nvarchar](1000) NULL,
	[fromAddressline] [nvarchar](1000) NULL,
	[fromCity] [nvarchar](1000) NULL,
	[fromStateCode] [nvarchar](1000) NULL,
	[fromPostalCode] [nvarchar](1000) NULL,
	[toPharmacyName] [nvarchar](1000) NULL,
	[toPhone] [nvarchar](1000) NULL,
	[toAddressline] [nvarchar](1000) NULL,
	[toCity] [nvarchar](1000) NULL,
	[toStateCode] [nvarchar](1000) NULL,
	[toPostalCode] [nvarchar](1000) NULL,
	[graphic_image] [varchar](max) NULL,
	[from_phone] [nvarchar](100) NULL,
	[order_received] [bit] NULL,
	[shipping_method_id] [int] NULL,
PRIMARY KEY CLUSTERED 
(
	[shippment_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
SET ANSI_PADDING OFF
GO
/****** Object:  Table [dbo].[shippmentdetails]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[shippmentdetails](
	[shippmentdetails_id] [int] IDENTITY(1,1) NOT NULL,
	[shippment_id] [int] NULL,
	[ndc] [bigint] NULL,
	[quantity] [decimal](10, 2) NULL,
	[unit_price] [decimal](10, 2) NULL,
	[created_by] [int] NULL,
	[created_on] [datetime] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[is_deletd] [bit] NULL,
	[deleted_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[exipry_date] [datetime] NULL,
	[lot_number] [nvarchar](500) NULL,
	[drug_name] [nvarchar](2000) NULL,
	[pack_size] [decimal](18, 2) NULL,
	[strength] [nvarchar](1000) NULL,
PRIMARY KEY CLUSTERED 
(
	[shippmentdetails_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[sister_pharmacy_mapping]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[sister_pharmacy_mapping](
	[sister_pharmacy_mapping_id] [int] IDENTITY(1,1) NOT NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
	[parent_pharmacy_id] [int] NULL,
	[sister_pharmacy_id] [int] NULL,
PRIMARY KEY CLUSTERED 
(
	[sister_pharmacy_mapping_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[subscription_module_assignment]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[subscription_module_assignment](
	[subscription_module_assignment_id] [int] IDENTITY(1,1) NOT NULL,
	[subscription_plan_id] [int] NULL,
	[pharmacy_module_id] [int] NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
	[is_hide] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[subscription_module_assignment_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[superadmin_login]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[superadmin_login](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[username] [nvarchar](50) NULL,
	[password] [nvarchar](50) NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY],
UNIQUE NONCLUSTERED 
(
	[username] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[Tickets]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[Tickets](
	[Ticket_Id] [int] IDENTITY(1,1) NOT NULL,
	[TicketStatus_Id] [int] NOT NULL,
	[Pharmacy_Id] [int] NOT NULL,
	[TicketNumber] [int] NOT NULL,
	[Problem_Definition] [nvarchar](500) NOT NULL,
	[TIX_RaisedDT] [datetime] NOT NULL,
	[TIX_ResolvedDT] [datetime] NULL,
	[TIX_ResolvedBY] [nvarchar](255) NULL,
	[Remarks] [nvarchar](500) NULL,
	[CreatedOn] [datetime] NOT NULL,
	[CreatedBy] [int] NOT NULL,
	[UpdatedOn] [datetime] NULL,
	[UpdatedBy] [int] NULL,
 CONSTRAINT [PK_dbo.Tickets] PRIMARY KEY CLUSTERED 
(
	[Ticket_Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[TicketStatus]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[TicketStatus](
	[Id] [int] IDENTITY(1,1) NOT NULL,
	[Status] [nvarchar](50) NOT NULL,
	[IsActive] [bit] NOT NULL,
 CONSTRAINT [PK_dbo.TicketStatus] PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[transfer_management]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[transfer_management](
	[transfer_mgmt_id] [bigint] IDENTITY(1,1) NOT NULL,
	[mp_postitem_id] [int] NULL,
	[updated_quantity] [int] NULL,
	[created_by] [int] NULL,
	[created_on] [datetime] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[is_deletd] [bit] NULL,
	[deleted_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[purchaser_pharmacy_id] [int] NULL,
	[seller_pharmacy_id] [int] NULL,
 CONSTRAINT [PK_transfer_management] PRIMARY KEY CLUSTERED 
(
	[transfer_mgmt_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[UserRoles]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[UserRoles](
	[UserId] [int] NOT NULL,
	[RoleId] [int] NOT NULL,
 CONSTRAINT [PK_UserRoles] PRIMARY KEY CLUSTERED 
(
	[UserId] ASC,
	[RoleId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[Users]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[Users](
	[Id] [int] IDENTITY(100,1) NOT NULL,
	[Email] [nvarchar](256) NULL,
	[EmailConfirmed] [bit] NOT NULL,
	[PasswordHash] [nvarchar](max) NULL,
	[PhoneNumber] [nvarchar](256) NULL,
	[PhoneNumberConfirmed] [bit] NOT NULL,
	[UserName] [nvarchar](256) NULL,
	[PasswordSalt] [nvarchar](max) NOT NULL,
	[pharmacy_id] [int] NULL,
 CONSTRAINT [PK_Users] PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY],
 CONSTRAINT [UNQ_EMAIL] UNIQUE NONCLUSTERED 
(
	[Email] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY],
 CONSTRAINT [UNQ_PHONE] UNIQUE NONCLUSTERED 
(
	[PhoneNumber] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY],
 CONSTRAINT [UNQ_USERNAME] UNIQUE NONCLUSTERED 
(
	[UserName] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
/****** Object:  Table [dbo].[wholesaler]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[wholesaler](
	[wholesaler_id] [int] IDENTITY(1,1) NOT NULL,
	[name] [nvarchar](1000) NULL,
	[email] [nvarchar](1000) NULL,
	[is_active] [bit] NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
	[pharmacy_id] [int] NULL,
PRIMARY KEY CLUSTERED 
(
	[wholesaler_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[wholesaler_CSV_Import]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[wholesaler_CSV_Import](
	[wholesaler_csv_id] [int] IDENTITY(1,1) NOT NULL,
	[drug_name] [nvarchar](500) NULL,
	[ndc] [bigint] NULL,
	[generic_code] [bigint] NULL,
	[pack_size] [decimal](18, 0) NULL,
	[tax] [decimal](18, 0) NULL,
	[price] [money] NULL,
	[response] [nvarchar](100) NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[deleted_on] [datetime] NULL,
	[deleted_by] [int] NULL,
	[is_deleted] [bit] NULL,
	[status_id] [int] NULL,
	[csvbatch_id] [int] NULL,
	[purchasedate] [datetime] NULL,
PRIMARY KEY CLUSTERED 
(
	[wholesaler_csv_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[wholesaler_csvimport_batch_details]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[wholesaler_csvimport_batch_details](
	[csvimport_batch_details_id] [int] IDENTITY(1,1) NOT NULL,
	[csvimport_batch_id] [int] NULL,
	[filename] [nvarchar](300) NULL,
	[is_success] [bit] NULL,
	[is_error] [bit] NULL,
	[no_of_records] [int] NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[is_deleted] [bit] NULL,
	[deleted_by] [int] NULL,
	[deleted_on] [datetime] NULL,
PRIMARY KEY CLUSTERED 
(
	[csvimport_batch_details_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Table [dbo].[wholesaler_csvimport_batch_master]    Script Date: 6/20/2019 10:23:08 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[wholesaler_csvimport_batch_master](
	[csvimport_batch_id] [int] IDENTITY(1,1) NOT NULL,
	[pharmacy_id] [int] NULL,
	[wholesaler_id] [int] NULL,
	[importdate] [datetime] NULL,
	[created_on] [datetime] NULL,
	[created_by] [int] NULL,
	[updated_on] [datetime] NULL,
	[updated_by] [int] NULL,
	[is_deleted] [bit] NULL,
	[deleted_by] [int] NULL,
	[deleted_on] [datetime] NULL,
PRIMARY KEY CLUSTERED 
(
	[csvimport_batch_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
) ON [PRIMARY]

GO
/****** Object:  Index [IX_Yaron]    Script Date: 6/20/2019 10:23:08 AM ******/
CREATE NONCLUSTERED INDEX [IX_Yaron] ON [dbo].[Ack_LineItem]
(
	[BAK_ID] ASC
)
INCLUDE ( 	[LineItem_ID]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
SET ANSI_PADDING ON

GO
/****** Object:  Index [ix_mp_inventory]    Script Date: 6/20/2019 10:23:08 AM ******/
CREATE NONCLUSTERED INDEX [ix_mp_inventory] ON [dbo].[inventory]
(
	[pharmacy_id] ASC
)
INCLUDE ( 	[wholesaler_id],
	[drug_name],
	[ndc],
	[price],
	[created_on],
	[is_deleted],
	[Strength],
	[pack_size]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [ix_mp_inventory_price]    Script Date: 6/20/2019 10:23:08 AM ******/
CREATE NONCLUSTERED INDEX [ix_mp_inventory_price] ON [dbo].[inventory]
(
	[pharmacy_id] ASC,
	[is_deleted] ASC,
	[created_on] ASC
)
INCLUDE ( 	[price]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [ix_mp_invoice_line_items]    Script Date: 6/20/2019 10:23:08 AM ******/
CREATE NONCLUSTERED INDEX [ix_mp_invoice_line_items] ON [dbo].[invoice_line_items]
(
	[invoice_id] ASC
)
INCLUDE ( 	[unit_price]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [ix_mp_rx30_inventory]    Script Date: 6/20/2019 10:23:08 AM ******/
CREATE NONCLUSTERED INDEX [ix_mp_rx30_inventory] ON [dbo].[RX30_inventory]
(
	[pharmacy_id] ASC,
	[is_deleted] ASC,
	[created_on] ASC
)
INCLUDE ( 	[plan_paid]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [ix_mp_wholesaler_csv_import]    Script Date: 6/20/2019 10:23:08 AM ******/
CREATE NONCLUSTERED INDEX [ix_mp_wholesaler_csv_import] ON [dbo].[wholesaler_CSV_Import]
(
	[csvbatch_id] ASC
)
INCLUDE ( 	[ndc],
	[pack_size],
	[purchasedate]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
ALTER TABLE [dbo].[Ack_BAK_PurchaseOrder] ADD  DEFAULT ((0)) FOR [isDeleted]
GO
ALTER TABLE [dbo].[edi_server_configuration] ADD  DEFAULT ((1)) FOR [IsActive]
GO
ALTER TABLE [dbo].[Roles] ADD  DEFAULT ((1)) FOR [IsActive]
GO
ALTER TABLE [dbo].[Roles] ADD  DEFAULT ((0)) FOR [IsDeleted]
GO
ALTER TABLE [dbo].[TicketStatus] ADD  DEFAULT ((1)) FOR [IsActive]
GO
ALTER TABLE [dbo].[Ack_BAK_PurchaseOrder]  WITH CHECK ADD  CONSTRAINT [FK_edibatchdetail_AckBAKPurchaseOrder_batchdetailsId] FOREIGN KEY([edi_batch_details_id])
REFERENCES [dbo].[edi_batch_details] ([edi_batch_details_id])
GO
ALTER TABLE [dbo].[Ack_BAK_PurchaseOrder] CHECK CONSTRAINT [FK_edibatchdetail_AckBAKPurchaseOrder_batchdetailsId]
GO
ALTER TABLE [dbo].[Ack_BAK_PurchaseOrder]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_Ack_BAK_PurchaseOrdere_pharmacy_id] FOREIGN KEY([pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[Ack_BAK_PurchaseOrder] CHECK CONSTRAINT [FK_pharmacy_Ack_BAK_PurchaseOrdere_pharmacy_id]
GO
ALTER TABLE [dbo].[Ack_BuyerPartyDetail]  WITH CHECK ADD  CONSTRAINT [FK_Ack_BuyerPartyDetail_Ack_BAK_PurchaseOrder] FOREIGN KEY([BAK_ID])
REFERENCES [dbo].[Ack_BAK_PurchaseOrder] ([BAK_ID])
GO
ALTER TABLE [dbo].[Ack_BuyerPartyDetail] CHECK CONSTRAINT [FK_Ack_BuyerPartyDetail_Ack_BAK_PurchaseOrder]
GO
ALTER TABLE [dbo].[Ack_LineItem]  WITH CHECK ADD  CONSTRAINT [FK_edibatchdetail_Ack_LineItem_batchdetailsId] FOREIGN KEY([edi_batch_details_id])
REFERENCES [dbo].[edi_batch_details] ([edi_batch_details_id])
GO
ALTER TABLE [dbo].[Ack_LineItem] CHECK CONSTRAINT [FK_edibatchdetail_Ack_LineItem_batchdetailsId]
GO
ALTER TABLE [dbo].[Ack_LineItem]  WITH CHECK ADD  CONSTRAINT [FK_LineItem_BAK_PurchaseOrder] FOREIGN KEY([BAK_ID])
REFERENCES [dbo].[Ack_BAK_PurchaseOrder] ([BAK_ID])
GO
ALTER TABLE [dbo].[Ack_LineItem] CHECK CONSTRAINT [FK_LineItem_BAK_PurchaseOrder]
GO
ALTER TABLE [dbo].[Ack_LineItem]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_Ack_LineItem_pharmacy_id] FOREIGN KEY([pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[Ack_LineItem] CHECK CONSTRAINT [FK_pharmacy_Ack_LineItem_pharmacy_id]
GO
ALTER TABLE [dbo].[Ack_LineItemACK]  WITH CHECK ADD  CONSTRAINT [FK_LineItem_LineItemACK] FOREIGN KEY([LineItem_ID])
REFERENCES [dbo].[Ack_LineItem] ([LineItem_ID])
GO
ALTER TABLE [dbo].[Ack_LineItemACK] CHECK CONSTRAINT [FK_LineItem_LineItemACK]
GO
ALTER TABLE [dbo].[address_master]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_address_pharmacy_id] FOREIGN KEY([pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[address_master] CHECK CONSTRAINT [FK_pharmacy_address_pharmacy_id]
GO
ALTER TABLE [dbo].[address_master]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_user_address_pharmacy_user_id] FOREIGN KEY([pharmacy_user_id])
REFERENCES [dbo].[pharmacy_users] ([pharmacy_user_id])
GO
ALTER TABLE [dbo].[address_master] CHECK CONSTRAINT [FK_pharmacy_user_address_pharmacy_user_id]
GO
ALTER TABLE [dbo].[address_master]  WITH CHECK ADD  CONSTRAINT [FK_wholesaler_address_wholesaler_id] FOREIGN KEY([wholesaler_id])
REFERENCES [dbo].[wholesaler] ([wholesaler_id])
GO
ALTER TABLE [dbo].[address_master] CHECK CONSTRAINT [FK_wholesaler_address_wholesaler_id]
GO
ALTER TABLE [dbo].[broadcast_message]  WITH CHECK ADD  CONSTRAINT [FK_broadcast_message_title_master_broadcast_message_broadcast_message_title_masterid] FOREIGN KEY([broadcast_message_title_masterid])
REFERENCES [dbo].[broadcast_message_title_master] ([broadcast_message_title_masterid])
GO
ALTER TABLE [dbo].[broadcast_message] CHECK CONSTRAINT [FK_broadcast_message_title_master_broadcast_message_broadcast_message_title_masterid]
GO
ALTER TABLE [dbo].[broadcast_message]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_broadcast_message_pharmacy_id] FOREIGN KEY([pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[broadcast_message] CHECK CONSTRAINT [FK_pharmacy_broadcast_message_pharmacy_id]
GO
ALTER TABLE [dbo].[broadcast_notification]  WITH CHECK ADD  CONSTRAINT [FK_broadcast_notification_title_master_broadcast_message_broadcast_message_title_masterid] FOREIGN KEY([broadcast_message_title_masterid])
REFERENCES [dbo].[broadcast_message_title_master] ([broadcast_message_title_masterid])
GO
ALTER TABLE [dbo].[broadcast_notification] CHECK CONSTRAINT [FK_broadcast_notification_title_master_broadcast_message_broadcast_message_title_masterid]
GO
ALTER TABLE [dbo].[broadcast_notification]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_broadcast_notification_pharmacy_id] FOREIGN KEY([pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[broadcast_notification] CHECK CONSTRAINT [FK_pharmacy_broadcast_notification_pharmacy_id]
GO
ALTER TABLE [dbo].[broadcast_notification]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_list_broadcast_notification_created_by] FOREIGN KEY([created_by])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[broadcast_notification] CHECK CONSTRAINT [FK_pharmacy_list_broadcast_notification_created_by]
GO
ALTER TABLE [dbo].[carddetails]  WITH CHECK ADD  CONSTRAINT [FK_carddetails_pharmacy_list_pharmacy_id] FOREIGN KEY([pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[carddetails] CHECK CONSTRAINT [FK_carddetails_pharmacy_list_pharmacy_id]
GO
ALTER TABLE [dbo].[edi_batch_details]  WITH CHECK ADD  CONSTRAINT [FK_edi_batch_master_edi_batch_details_batch_id] FOREIGN KEY([edi_batch_id])
REFERENCES [dbo].[edi_batch_master] ([edi_batch_id])
GO
ALTER TABLE [dbo].[edi_batch_details] CHECK CONSTRAINT [FK_edi_batch_master_edi_batch_details_batch_id]
GO
ALTER TABLE [dbo].[edi_batch_master]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_edi_batch_master_pharmacy_id] FOREIGN KEY([pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[edi_batch_master] CHECK CONSTRAINT [FK_pharmacy_edi_batch_master_pharmacy_id]
GO
ALTER TABLE [dbo].[edi_file_Info]  WITH CHECK ADD  CONSTRAINT [FK_edi_batch_details_edi_file_Info_edi_batch_details_id] FOREIGN KEY([edi_batch_details_id])
REFERENCES [dbo].[edi_batch_details] ([edi_batch_details_id])
GO
ALTER TABLE [dbo].[edi_file_Info] CHECK CONSTRAINT [FK_edi_batch_details_edi_file_Info_edi_batch_details_id]
GO
ALTER TABLE [dbo].[edi_file_Info]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_edi_file_Info_pharmacy_id] FOREIGN KEY([pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[edi_file_Info] CHECK CONSTRAINT [FK_pharmacy_edi_file_Info_pharmacy_id]
GO
ALTER TABLE [dbo].[edi_inventory]  WITH CHECK ADD  CONSTRAINT [FK_edi_batch_details_edi_inventory_edi_batch_details_id] FOREIGN KEY([edi_batch_details_id])
REFERENCES [dbo].[edi_batch_details] ([edi_batch_details_id])
GO
ALTER TABLE [dbo].[edi_inventory] CHECK CONSTRAINT [FK_edi_batch_details_edi_inventory_edi_batch_details_id]
GO
ALTER TABLE [dbo].[edi_inventory]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_edi_inventory_pharmacy_id] FOREIGN KEY([pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[edi_inventory] CHECK CONSTRAINT [FK_pharmacy_edi_inventory_pharmacy_id]
GO
ALTER TABLE [dbo].[edi_inventory]  WITH CHECK ADD  CONSTRAINT [FK_statusID] FOREIGN KEY([status_id])
REFERENCES [dbo].[edi_inventories_status] ([status_id])
GO
ALTER TABLE [dbo].[edi_inventory] CHECK CONSTRAINT [FK_statusID]
GO
ALTER TABLE [dbo].[edi_inventory]  WITH CHECK ADD  CONSTRAINT [FK_wholesaler_edi_inventry_wholesaler_id] FOREIGN KEY([wholesaler_id])
REFERENCES [dbo].[wholesaler] ([wholesaler_id])
GO
ALTER TABLE [dbo].[edi_inventory] CHECK CONSTRAINT [FK_wholesaler_edi_inventry_wholesaler_id]
GO
ALTER TABLE [dbo].[edi_server_configuration]  WITH CHECK ADD  CONSTRAINT [FK_wholesaler_id_edi_config_id] FOREIGN KEY([wholeseller_id])
REFERENCES [dbo].[wholesaler] ([wholesaler_id])
GO
ALTER TABLE [dbo].[edi_server_configuration] CHECK CONSTRAINT [FK_wholesaler_id_edi_config_id]
GO
ALTER TABLE [dbo].[inventory]  WITH CHECK ADD  CONSTRAINT [FK_inventory_source_master_inventory_inventory_source_id] FOREIGN KEY([inventory_source_id])
REFERENCES [dbo].[inventory_source_master] ([inventory_source_master_id])
GO
ALTER TABLE [dbo].[inventory] CHECK CONSTRAINT [FK_inventory_source_master_inventory_inventory_source_id]
GO
ALTER TABLE [dbo].[inventory]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_inventory_pharmacy_id] FOREIGN KEY([pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[inventory] CHECK CONSTRAINT [FK_pharmacy_inventory_pharmacy_id]
GO
ALTER TABLE [dbo].[inventory]  WITH CHECK ADD  CONSTRAINT [FK_wholesaler_inventry_wholesaler_id] FOREIGN KEY([wholesaler_id])
REFERENCES [dbo].[wholesaler] ([wholesaler_id])
GO
ALTER TABLE [dbo].[inventory] CHECK CONSTRAINT [FK_wholesaler_inventry_wholesaler_id]
GO
ALTER TABLE [dbo].[invoice]  WITH CHECK ADD  CONSTRAINT [FK_invoice_order_order_id] FOREIGN KEY([order_id])
REFERENCES [dbo].[orders] ([order_id])
GO
ALTER TABLE [dbo].[invoice] CHECK CONSTRAINT [FK_invoice_order_order_id]
GO
ALTER TABLE [dbo].[invoice]  WITH CHECK ADD  CONSTRAINT [FK_invoice_status_invoice_status_id] FOREIGN KEY([invoice_status_id])
REFERENCES [dbo].[pharmacy_invoice_status_master] ([invoice_status_id])
GO
ALTER TABLE [dbo].[invoice] CHECK CONSTRAINT [FK_invoice_status_invoice_status_id]
GO
ALTER TABLE [dbo].[invoice]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_invoice_pharmacy_id] FOREIGN KEY([pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[invoice] CHECK CONSTRAINT [FK_pharmacy_invoice_pharmacy_id]
GO
ALTER TABLE [dbo].[invoice_additionalItem]  WITH CHECK ADD  CONSTRAINT [FK_additionalitem_invoicelineitems_id] FOREIGN KEY([invoice_items_id])
REFERENCES [dbo].[invoice_line_items] ([invoice_lineitem_id])
GO
ALTER TABLE [dbo].[invoice_additionalItem] CHECK CONSTRAINT [FK_additionalitem_invoicelineitems_id]
GO
ALTER TABLE [dbo].[invoice_billcontacts]  WITH CHECK ADD  CONSTRAINT [FK_invoicebillcontacts_invoicebillingdetails_id] FOREIGN KEY([invoice_billing_id])
REFERENCES [dbo].[invoice_billing_details] ([invoice_billing_id])
GO
ALTER TABLE [dbo].[invoice_billcontacts] CHECK CONSTRAINT [FK_invoicebillcontacts_invoicebillingdetails_id]
GO
ALTER TABLE [dbo].[invoice_billing_details]  WITH CHECK ADD  CONSTRAINT [FK_billingdetail_invoice_id] FOREIGN KEY([invoice_id])
REFERENCES [dbo].[invoice] ([invoice_id])
GO
ALTER TABLE [dbo].[invoice_billing_details] CHECK CONSTRAINT [FK_billingdetail_invoice_id]
GO
ALTER TABLE [dbo].[invoice_line_items]  WITH CHECK ADD  CONSTRAINT [FK_lineitems_invoice_id] FOREIGN KEY([invoice_id])
REFERENCES [dbo].[invoice] ([invoice_id])
GO
ALTER TABLE [dbo].[invoice_line_items] CHECK CONSTRAINT [FK_lineitems_invoice_id]
GO
ALTER TABLE [dbo].[invoice_productDescription]  WITH CHECK ADD  CONSTRAINT [FK_proddesc_invoicelineitems_id] FOREIGN KEY([invoice_items_id])
REFERENCES [dbo].[invoice_line_items] ([invoice_lineitem_id])
GO
ALTER TABLE [dbo].[invoice_productDescription] CHECK CONSTRAINT [FK_proddesc_invoicelineitems_id]
GO
ALTER TABLE [dbo].[invoice_SAC]  WITH CHECK ADD  CONSTRAINT [FK_sac_invoicelineitems_id] FOREIGN KEY([invoice_items_id])
REFERENCES [dbo].[invoice_line_items] ([invoice_lineitem_id])
GO
ALTER TABLE [dbo].[invoice_SAC] CHECK CONSTRAINT [FK_sac_invoicelineitems_id]
GO
ALTER TABLE [dbo].[invoice_shipping_details]  WITH CHECK ADD  CONSTRAINT [FK_shippingdetail_invoice_id] FOREIGN KEY([invoice_id])
REFERENCES [dbo].[invoice] ([invoice_id])
GO
ALTER TABLE [dbo].[invoice_shipping_details] CHECK CONSTRAINT [FK_shippingdetail_invoice_id]
GO
ALTER TABLE [dbo].[invoice_taxes]  WITH CHECK ADD  CONSTRAINT [FK_invoicetaxes_invoice_id] FOREIGN KEY([invoice_id])
REFERENCES [dbo].[invoice] ([invoice_id])
GO
ALTER TABLE [dbo].[invoice_taxes] CHECK CONSTRAINT [FK_invoicetaxes_invoice_id]
GO
ALTER TABLE [dbo].[marketplace_drugpost_notification]  WITH CHECK ADD  CONSTRAINT [FK_marketplace_drugpost_notification_pharmacy_id] FOREIGN KEY([pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[marketplace_drugpost_notification] CHECK CONSTRAINT [FK_marketplace_drugpost_notification_pharmacy_id]
GO
ALTER TABLE [dbo].[marketplace_drugpost_notification]  WITH CHECK ADD  CONSTRAINT [FK_mp_post_items_marketplace_drugpost_notification_mp_postitem_id] FOREIGN KEY([mp_postitem_id])
REFERENCES [dbo].[mp_post_items] ([mp_postitem_id])
GO
ALTER TABLE [dbo].[marketplace_drugpost_notification] CHECK CONSTRAINT [FK_mp_post_items_marketplace_drugpost_notification_mp_postitem_id]
GO
ALTER TABLE [dbo].[marketplace_drugpurchase_notification]  WITH CHECK ADD  CONSTRAINT [FK_marketplace_drugpurchase_pharmacy_purchaser_pharmacy_id] FOREIGN KEY([purchaser_pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[marketplace_drugpurchase_notification] CHECK CONSTRAINT [FK_marketplace_drugpurchase_pharmacy_purchaser_pharmacy_id]
GO
ALTER TABLE [dbo].[marketplace_drugpurchase_notification]  WITH CHECK ADD  CONSTRAINT [FK_marketplace_drugpurchase_pharmacy_seller_pharmacy_id] FOREIGN KEY([sellerpharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[marketplace_drugpurchase_notification] CHECK CONSTRAINT [FK_marketplace_drugpurchase_pharmacy_seller_pharmacy_id]
GO
ALTER TABLE [dbo].[marketplace_drugpurchase_notification]  WITH CHECK ADD  CONSTRAINT [FK_mp_post_items_marketplace_drugpurchase_notification_mp_postitem_id] FOREIGN KEY([mp_postitem_id])
REFERENCES [dbo].[mp_post_items] ([mp_postitem_id])
GO
ALTER TABLE [dbo].[marketplace_drugpurchase_notification] CHECK CONSTRAINT [FK_mp_post_items_marketplace_drugpurchase_notification_mp_postitem_id]
GO
ALTER TABLE [dbo].[marketplace_drugpurchase_notification]  WITH CHECK ADD  CONSTRAINT [FK_mp_post_items_marketplace_drugpurchase_notification_transfermgt_id] FOREIGN KEY([Transfer_Mgt_Id])
REFERENCES [dbo].[transfer_management] ([transfer_mgmt_id])
GO
ALTER TABLE [dbo].[marketplace_drugpurchase_notification] CHECK CONSTRAINT [FK_mp_post_items_marketplace_drugpurchase_notification_transfermgt_id]
GO
ALTER TABLE [dbo].[master_city]  WITH CHECK ADD FOREIGN KEY([state_id])
REFERENCES [dbo].[master_state] ([state_id])
GO
ALTER TABLE [dbo].[master_state]  WITH CHECK ADD FOREIGN KEY([countryid])
REFERENCES [dbo].[master_country] ([countryid])
GO
ALTER TABLE [dbo].[medicine]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_medicine_pharmacy_id] FOREIGN KEY([pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[medicine] CHECK CONSTRAINT [FK_pharmacy_medicine_pharmacy_id]
GO
ALTER TABLE [dbo].[mp_post_items]  WITH CHECK ADD  CONSTRAINT [FK_mp_network_type_mp_post_items_pharmacy_id] FOREIGN KEY([mp_network_type_id])
REFERENCES [dbo].[mp_network_type] ([mp_network_type_id])
GO
ALTER TABLE [dbo].[mp_post_items] CHECK CONSTRAINT [FK_mp_network_type_mp_post_items_pharmacy_id]
GO
ALTER TABLE [dbo].[mp_post_items]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_mp_post_items_pharmacy_id] FOREIGN KEY([pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[mp_post_items] CHECK CONSTRAINT [FK_pharmacy_mp_post_items_pharmacy_id]
GO
ALTER TABLE [dbo].[order_details]  WITH CHECK ADD  CONSTRAINT [FK_medicine_order_details_medicine_id] FOREIGN KEY([medicine_id])
REFERENCES [dbo].[medicine] ([medicine_id])
GO
ALTER TABLE [dbo].[order_details] CHECK CONSTRAINT [FK_medicine_order_details_medicine_id]
GO
ALTER TABLE [dbo].[order_details]  WITH CHECK ADD  CONSTRAINT [FK_order_order_details_order_id] FOREIGN KEY([order_id])
REFERENCES [dbo].[orders] ([order_id])
GO
ALTER TABLE [dbo].[order_details] CHECK CONSTRAINT [FK_order_order_details_order_id]
GO
ALTER TABLE [dbo].[orders]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_order_pharmacy_id] FOREIGN KEY([pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[orders] CHECK CONSTRAINT [FK_pharmacy_order_pharmacy_id]
GO
ALTER TABLE [dbo].[orders]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_order_status_order_status_id] FOREIGN KEY([order_status_id])
REFERENCES [dbo].[pharmacy_order_status_master] ([order_status_id])
GO
ALTER TABLE [dbo].[orders] CHECK CONSTRAINT [FK_pharmacy_order_status_order_status_id]
GO
ALTER TABLE [dbo].[orders]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_wholesaler_wholesaler_id] FOREIGN KEY([wholesaler_id])
REFERENCES [dbo].[wholesaler] ([wholesaler_id])
GO
ALTER TABLE [dbo].[orders] CHECK CONSTRAINT [FK_pharmacy_wholesaler_wholesaler_id]
GO
ALTER TABLE [dbo].[payments]  WITH CHECK ADD  CONSTRAINT [FK_payment_pharmacy_list_pharmacy_id] FOREIGN KEY([pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[payments] CHECK CONSTRAINT [FK_payment_pharmacy_list_pharmacy_id]
GO
ALTER TABLE [dbo].[pending_reorder]  WITH CHECK ADD  CONSTRAINT [FK_pending_order_rx30_batch_details_id] FOREIGN KEY([rx30_batch_details_id])
REFERENCES [dbo].[rx30_batch_details] ([rx30_batch_details_id])
GO
ALTER TABLE [dbo].[pending_reorder] CHECK CONSTRAINT [FK_pending_order_rx30_batch_details_id]
GO
ALTER TABLE [dbo].[pending_reorder]  WITH CHECK ADD  CONSTRAINT [FK_pending_order_rx30_inventory_id] FOREIGN KEY([rx30_inventory_id])
REFERENCES [dbo].[RX30_inventory] ([rx30_inventory_id])
GO
ALTER TABLE [dbo].[pending_reorder] CHECK CONSTRAINT [FK_pending_order_rx30_inventory_id]
GO
ALTER TABLE [dbo].[pending_reorder_log]  WITH CHECK ADD  CONSTRAINT [FK_pending_reorder_log_pending_reorder_id] FOREIGN KEY([pending_reorder_id])
REFERENCES [dbo].[pending_reorder] ([pending_reorder_id])
GO
ALTER TABLE [dbo].[pending_reorder_log] CHECK CONSTRAINT [FK_pending_reorder_log_pending_reorder_id]
GO
ALTER TABLE [dbo].[ph_messageboard]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_messageboard_from_ph_id] FOREIGN KEY([from_ph_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[ph_messageboard] CHECK CONSTRAINT [FK_pharmacy_messageboard_from_ph_id]
GO
ALTER TABLE [dbo].[ph_messageboard]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_messageboard_to_ph_id] FOREIGN KEY([to_ph_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[ph_messageboard] CHECK CONSTRAINT [FK_pharmacy_messageboard_to_ph_id]
GO
ALTER TABLE [dbo].[pharmacy_business_profile]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_pharmacy_business_profile_pharmacy_id] FOREIGN KEY([pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[pharmacy_business_profile] CHECK CONSTRAINT [FK_pharmacy_pharmacy_business_profile_pharmacy_id]
GO
ALTER TABLE [dbo].[pharmacy_list]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_sa_pharmacy_owner_pharmacy_owner_id] FOREIGN KEY([pharmacy_owner_id])
REFERENCES [dbo].[sa_pharmacy_owner] ([pharmacy_owner_id])
GO
ALTER TABLE [dbo].[pharmacy_list] CHECK CONSTRAINT [FK_pharmacy_sa_pharmacy_owner_pharmacy_owner_id]
GO
ALTER TABLE [dbo].[pharmacy_list]  WITH CHECK ADD  CONSTRAINT [FK_Pharmacy_sa_subscription_plan_subscription_plan_id] FOREIGN KEY([subscription_plan_id])
REFERENCES [dbo].[sa_subscription_plan] ([subscription_plan_id])
GO
ALTER TABLE [dbo].[pharmacy_list] CHECK CONSTRAINT [FK_Pharmacy_sa_subscription_plan_subscription_plan_id]
GO
ALTER TABLE [dbo].[pharmacy_notification_setting]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_pharmacy_notification_setting_pharmacy_id] FOREIGN KEY([pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[pharmacy_notification_setting] CHECK CONSTRAINT [FK_pharmacy_pharmacy_notification_setting_pharmacy_id]
GO
ALTER TABLE [dbo].[pharmacy_report_setting]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_pharmacy_report_setting_pharmacy_id] FOREIGN KEY([pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[pharmacy_report_setting] CHECK CONSTRAINT [FK_pharmacy_pharmacy_report_setting_pharmacy_id]
GO
ALTER TABLE [dbo].[pharmacy_role_module_assignment]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_module_master_pharmacy_role_module_assignment_module_id] FOREIGN KEY([module_id])
REFERENCES [dbo].[pharmacy_module_master] ([pharmacy_module_id])
GO
ALTER TABLE [dbo].[pharmacy_role_module_assignment] CHECK CONSTRAINT [FK_pharmacy_module_master_pharmacy_role_module_assignment_module_id]
GO
ALTER TABLE [dbo].[pharmacy_role_module_assignment]  WITH CHECK ADD  CONSTRAINT [FK_Roles_pharmacy_role_module_assignment_role_id] FOREIGN KEY([role_id])
REFERENCES [dbo].[Roles] ([Id])
GO
ALTER TABLE [dbo].[pharmacy_role_module_assignment] CHECK CONSTRAINT [FK_Roles_pharmacy_role_module_assignment_role_id]
GO
ALTER TABLE [dbo].[pharmacy_ups_account]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_pharmacy_ups_account_pharmacy_id] FOREIGN KEY([pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[pharmacy_ups_account] CHECK CONSTRAINT [FK_pharmacy_pharmacy_ups_account_pharmacy_id]
GO
ALTER TABLE [dbo].[pharmacy_users]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_pharmacy_users_pharmacy_id] FOREIGN KEY([pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[pharmacy_users] CHECK CONSTRAINT [FK_pharmacy_pharmacy_users_pharmacy_id]
GO
ALTER TABLE [dbo].[pharmacy_users]  WITH CHECK ADD  CONSTRAINT [FK_PharmacyUser_pharmacyRoleId] FOREIGN KEY([pharmacy_user_role_id])
REFERENCES [dbo].[pharmacy_users_roles_master] ([pharmacy_user_role_id])
GO
ALTER TABLE [dbo].[pharmacy_users] CHECK CONSTRAINT [FK_PharmacyUser_pharmacyRoleId]
GO
ALTER TABLE [dbo].[pharmacy_users_roles_assignment]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_users_users_roles_pharmacy_user_role_id] FOREIGN KEY([pharmacy_user_role_id])
REFERENCES [dbo].[pharmacy_users_roles_master] ([pharmacy_user_role_id])
GO
ALTER TABLE [dbo].[pharmacy_users_roles_assignment] CHECK CONSTRAINT [FK_pharmacy_users_users_roles_pharmacy_user_role_id]
GO
ALTER TABLE [dbo].[pharmacy_users_roles_assignment]  WITH CHECK ADD  CONSTRAINT [FK_pharmacyusers_users_roles_assignment_pharmacy_user_id] FOREIGN KEY([pharmacy_user_id])
REFERENCES [dbo].[pharmacy_users] ([pharmacy_user_id])
GO
ALTER TABLE [dbo].[pharmacy_users_roles_assignment] CHECK CONSTRAINT [FK_pharmacyusers_users_roles_assignment_pharmacy_user_id]
GO
ALTER TABLE [dbo].[pre_shippmentorder]  WITH CHECK ADD  CONSTRAINT [FK_mp_post_items_pre_shippmentorder_mp_postitem_id] FOREIGN KEY([mp_postitem_id])
REFERENCES [dbo].[mp_post_items] ([mp_postitem_id])
GO
ALTER TABLE [dbo].[pre_shippmentorder] CHECK CONSTRAINT [FK_mp_post_items_pre_shippmentorder_mp_postitem_id]
GO
ALTER TABLE [dbo].[pre_shippmentorder]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_list_pre_shippmentorder_purchaser_pharmacy_id] FOREIGN KEY([purchaser_pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[pre_shippmentorder] CHECK CONSTRAINT [FK_pharmacy_list_pre_shippmentorder_purchaser_pharmacy_id]
GO
ALTER TABLE [dbo].[pre_shippmentorder]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_list_pre_shippmentorder_seller_pharmacy_id] FOREIGN KEY([seller_pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[pre_shippmentorder] CHECK CONSTRAINT [FK_pharmacy_list_pre_shippmentorder_seller_pharmacy_id]
GO
ALTER TABLE [dbo].[pre_shippmentorder]  WITH CHECK ADD  CONSTRAINT [FK_shipping_methods_ShippingMethodID] FOREIGN KEY([shipping_method_id])
REFERENCES [dbo].[shipping_methods] ([shipping_method_id])
GO
ALTER TABLE [dbo].[pre_shippmentorder] CHECK CONSTRAINT [FK_shipping_methods_ShippingMethodID]
GO
ALTER TABLE [dbo].[pre_shippmentorder]  WITH CHECK ADD  CONSTRAINT [FK_shipping_status_master_pre_shippmentorder_shipping_status_master_id] FOREIGN KEY([shipping_status_master_id])
REFERENCES [dbo].[shipping_status_master] ([shipping_status_master_id])
GO
ALTER TABLE [dbo].[pre_shippmentorder] CHECK CONSTRAINT [FK_shipping_status_master_pre_shippmentorder_shipping_status_master_id]
GO
ALTER TABLE [dbo].[return_to_wholesaler_items]  WITH CHECK ADD  CONSTRAINT [returntowholesaler_retuntowholesaler_id] FOREIGN KEY([returntowholesaler_Id])
REFERENCES [dbo].[ReturnToWholesaler] ([returntowholesaler_Id])
GO
ALTER TABLE [dbo].[return_to_wholesaler_items] CHECK CONSTRAINT [returntowholesaler_retuntowholesaler_id]
GO
ALTER TABLE [dbo].[rx30_batch_details]  WITH CHECK ADD  CONSTRAINT [FK_rx30_batch_master_rx30_batch_details_batch_id] FOREIGN KEY([rx30_batch_id])
REFERENCES [dbo].[rx30_batch_master] ([rx30_batch_id])
GO
ALTER TABLE [dbo].[rx30_batch_details] CHECK CONSTRAINT [FK_rx30_batch_master_rx30_batch_details_batch_id]
GO
ALTER TABLE [dbo].[rx30_batch_master]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_rx30_batch_master_pharmacy_id] FOREIGN KEY([pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[rx30_batch_master] CHECK CONSTRAINT [FK_pharmacy_rx30_batch_master_pharmacy_id]
GO
ALTER TABLE [dbo].[rx30_configfolderpath]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_rx30_configfolderpath_pharmacy_id] FOREIGN KEY([pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[rx30_configfolderpath] CHECK CONSTRAINT [FK_pharmacy_rx30_configfolderpath_pharmacy_id]
GO
ALTER TABLE [dbo].[RX30_inventory]  WITH NOCHECK ADD  CONSTRAINT [FK_pharmacy_rx30_inventory_pharmacy_id] FOREIGN KEY([pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[RX30_inventory] CHECK CONSTRAINT [FK_pharmacy_rx30_inventory_pharmacy_id]
GO
ALTER TABLE [dbo].[RX30_inventory]  WITH NOCHECK ADD  CONSTRAINT [FK_rx30_batch_details_rx30_inventory_rx30_batch_details_id] FOREIGN KEY([rx30_batch_details_id])
REFERENCES [dbo].[rx30_batch_details] ([rx30_batch_details_id])
GO
ALTER TABLE [dbo].[RX30_inventory] CHECK CONSTRAINT [FK_rx30_batch_details_rx30_inventory_rx30_batch_details_id]
GO
ALTER TABLE [dbo].[RX30_inventory]  WITH NOCHECK ADD  CONSTRAINT [FK_rx30_status_master_RX30_inventory_status] FOREIGN KEY([status])
REFERENCES [dbo].[rx30_status_master] ([status_id])
GO
ALTER TABLE [dbo].[RX30_inventory] CHECK CONSTRAINT [FK_rx30_status_master_RX30_inventory_status]
GO
ALTER TABLE [dbo].[RX30_inventory]  WITH NOCHECK ADD  CONSTRAINT [FK_wholesaler_rx30_inventry_wholesaler_id] FOREIGN KEY([wholesaler_id])
REFERENCES [dbo].[wholesaler] ([wholesaler_id])
GO
ALTER TABLE [dbo].[RX30_inventory] CHECK CONSTRAINT [FK_wholesaler_rx30_inventry_wholesaler_id]
GO
ALTER TABLE [dbo].[sa_invoice_payment_details]  WITH CHECK ADD  CONSTRAINT [FK_paymentdetails_sinvoice_sinvoiceid] FOREIGN KEY([superadmin_invoice_id])
REFERENCES [dbo].[sa_superadmin_invoice] ([superadmin_invoice_id])
GO
ALTER TABLE [dbo].[sa_invoice_payment_details] CHECK CONSTRAINT [FK_paymentdetails_sinvoice_sinvoiceid]
GO
ALTER TABLE [dbo].[sa_pharmacy_subscription]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_subscription_subscriptionplanid] FOREIGN KEY([subscription_plan_id])
REFERENCES [dbo].[sa_subscription_plan] ([subscription_plan_id])
GO
ALTER TABLE [dbo].[sa_pharmacy_subscription] CHECK CONSTRAINT [FK_pharmacy_subscription_subscriptionplanid]
GO
ALTER TABLE [dbo].[sa_superadmin_invoice]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_sa_superadmin_invoice_pharmacy_id] FOREIGN KEY([pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[sa_superadmin_invoice] CHECK CONSTRAINT [FK_pharmacy_sa_superadmin_invoice_pharmacy_id]
GO
ALTER TABLE [dbo].[sa_superadmin_invoice]  WITH CHECK ADD  CONSTRAINT [FK_sinvoice_subscriptionplan_subscriptionplanid] FOREIGN KEY([subscription_plan_id])
REFERENCES [dbo].[sa_subscription_plan] ([subscription_plan_id])
GO
ALTER TABLE [dbo].[sa_superadmin_invoice] CHECK CONSTRAINT [FK_sinvoice_subscriptionplan_subscriptionplanid]
GO
ALTER TABLE [dbo].[sa_superAdmin_sddress]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_sa_superAdmin_sddress_pharmacy_id] FOREIGN KEY([pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[sa_superAdmin_sddress] CHECK CONSTRAINT [FK_pharmacy_sa_superAdmin_sddress_pharmacy_id]
GO
ALTER TABLE [dbo].[sa_superAdmin_sddress]  WITH CHECK ADD  CONSTRAINT [FK_SuperAdminAddress_Pharmacy_PharmacyOwnerid] FOREIGN KEY([pharmacy_owner_id])
REFERENCES [dbo].[sa_pharmacy_owner] ([pharmacy_owner_id])
GO
ALTER TABLE [dbo].[sa_superAdmin_sddress] CHECK CONSTRAINT [FK_SuperAdminAddress_Pharmacy_PharmacyOwnerid]
GO
ALTER TABLE [dbo].[shippment]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_list_shippment_purchaser_pharmacy_id] FOREIGN KEY([purchaser_pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[shippment] CHECK CONSTRAINT [FK_pharmacy_list_shippment_purchaser_pharmacy_id]
GO
ALTER TABLE [dbo].[shippment]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_list_shippment_seller_pharmacy_id] FOREIGN KEY([seller_pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[shippment] CHECK CONSTRAINT [FK_pharmacy_list_shippment_seller_pharmacy_id]
GO
ALTER TABLE [dbo].[shippment]  WITH CHECK ADD  CONSTRAINT [FK_shipment_method_ShippingMethodID] FOREIGN KEY([shipping_method_id])
REFERENCES [dbo].[shipping_methods] ([shipping_method_id])
GO
ALTER TABLE [dbo].[shippment] CHECK CONSTRAINT [FK_shipment_method_ShippingMethodID]
GO
ALTER TABLE [dbo].[shippment]  WITH CHECK ADD  CONSTRAINT [FK_shipping_status_master_shippment_shipping_status_master_id] FOREIGN KEY([shipping_status_master_id])
REFERENCES [dbo].[shipping_status_master] ([shipping_status_master_id])
GO
ALTER TABLE [dbo].[shippment] CHECK CONSTRAINT [FK_shipping_status_master_shippment_shipping_status_master_id]
GO
ALTER TABLE [dbo].[shippmentdetails]  WITH CHECK ADD  CONSTRAINT [FK_shippment_shippmentdetails_shippment_id] FOREIGN KEY([shippment_id])
REFERENCES [dbo].[shippment] ([shippment_id])
GO
ALTER TABLE [dbo].[shippmentdetails] CHECK CONSTRAINT [FK_shippment_shippmentdetails_shippment_id]
GO
ALTER TABLE [dbo].[sister_pharmacy_mapping]  WITH CHECK ADD  CONSTRAINT [FK_sister_pharmacy_mapping_pharmacy_parent_pharmacy_id] FOREIGN KEY([parent_pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[sister_pharmacy_mapping] CHECK CONSTRAINT [FK_sister_pharmacy_mapping_pharmacy_parent_pharmacy_id]
GO
ALTER TABLE [dbo].[sister_pharmacy_mapping]  WITH CHECK ADD  CONSTRAINT [FK_sister_pharmacy_mapping_pharmacy_sister_pharmacy_id] FOREIGN KEY([sister_pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[sister_pharmacy_mapping] CHECK CONSTRAINT [FK_sister_pharmacy_mapping_pharmacy_sister_pharmacy_id]
GO
ALTER TABLE [dbo].[subscription_module_assignment]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_module_master_subscription_module_assignment_pharmacy_module_id] FOREIGN KEY([pharmacy_module_id])
REFERENCES [dbo].[pharmacy_module_master] ([pharmacy_module_id])
GO
ALTER TABLE [dbo].[subscription_module_assignment] CHECK CONSTRAINT [FK_pharmacy_module_master_subscription_module_assignment_pharmacy_module_id]
GO
ALTER TABLE [dbo].[subscription_module_assignment]  WITH CHECK ADD  CONSTRAINT [FK_subscription_subscription_module_assignment_subscription_plan_id] FOREIGN KEY([subscription_plan_id])
REFERENCES [dbo].[sa_subscription_plan] ([subscription_plan_id])
GO
ALTER TABLE [dbo].[subscription_module_assignment] CHECK CONSTRAINT [FK_subscription_subscription_module_assignment_subscription_plan_id]
GO
ALTER TABLE [dbo].[Tickets]  WITH CHECK ADD  CONSTRAINT [FK_Tickets_Pharmacy_Pharmacy_Id] FOREIGN KEY([Pharmacy_Id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[Tickets] CHECK CONSTRAINT [FK_Tickets_Pharmacy_Pharmacy_Id]
GO
ALTER TABLE [dbo].[Tickets]  WITH CHECK ADD  CONSTRAINT [FK_Tickets_TicketStatus_Id] FOREIGN KEY([TicketStatus_Id])
REFERENCES [dbo].[TicketStatus] ([Id])
GO
ALTER TABLE [dbo].[Tickets] CHECK CONSTRAINT [FK_Tickets_TicketStatus_Id]
GO
ALTER TABLE [dbo].[transfer_management]  WITH CHECK ADD  CONSTRAINT [FK_mppostitenid_transfermgmt_postitemid] FOREIGN KEY([mp_postitem_id])
REFERENCES [dbo].[mp_post_items] ([mp_postitem_id])
GO
ALTER TABLE [dbo].[transfer_management] CHECK CONSTRAINT [FK_mppostitenid_transfermgmt_postitemid]
GO
ALTER TABLE [dbo].[transfer_management]  WITH CHECK ADD  CONSTRAINT [FK_transfer_management_pharmacy_purchaser_pharmacy_id] FOREIGN KEY([purchaser_pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[transfer_management] CHECK CONSTRAINT [FK_transfer_management_pharmacy_purchaser_pharmacy_id]
GO
ALTER TABLE [dbo].[transfer_management]  WITH CHECK ADD  CONSTRAINT [FK_transfer_management_pharmacy_seller_pharmacy_id] FOREIGN KEY([seller_pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[transfer_management] CHECK CONSTRAINT [FK_transfer_management_pharmacy_seller_pharmacy_id]
GO
ALTER TABLE [dbo].[wholesaler]  WITH CHECK ADD  CONSTRAINT [FK_pharmacy_wholesaler_pharmacy_id] FOREIGN KEY([pharmacy_id])
REFERENCES [dbo].[pharmacy_list] ([pharmacy_id])
GO
ALTER TABLE [dbo].[wholesaler] CHECK CONSTRAINT [FK_pharmacy_wholesaler_pharmacy_id]
GO
ALTER TABLE [dbo].[wholesaler_CSV_Import]  WITH NOCHECK ADD  CONSTRAINT [FK_wholesaler_CSV_Import_import_status_status_id] FOREIGN KEY([status_id])
REFERENCES [dbo].[csv_import_status] ([status_id])
GO
ALTER TABLE [dbo].[wholesaler_CSV_Import] CHECK CONSTRAINT [FK_wholesaler_CSV_Import_import_status_status_id]
GO
ALTER TABLE [dbo].[wholesaler_csvimport_batch_details]  WITH CHECK ADD  CONSTRAINT [FK_csvimport_batch_detailid] FOREIGN KEY([csvimport_batch_id])
REFERENCES [dbo].[wholesaler_csvimport_batch_master] ([csvimport_batch_id])
GO
ALTER TABLE [dbo].[wholesaler_csvimport_batch_details] CHECK CONSTRAINT [FK_csvimport_batch_detailid]
GO
USE [master]
GO
ALTER DATABASE [inviewanalytics] SET  READ_WRITE 
GO
